# -*- coding: utf-8 -*-
"""索引构建器：扫描本地抖音数据 → SQLite。

数据源：
  data/.appdata/db_videos.js   33,001 条  authorId / createTime / diggCount / audioId / size
  data/.appdata/db_texts.js    33,001 条  文案
  data/.appdata/db_authors.js   4,724 个  昵称 / secUid / 部分粉丝数
  data/关注/<作者ID>/视频/<vid>.mp4     19,804
  data/收藏/视频/<vid>.mp4              11,962（平铺）
  data/关注/<作者ID>/封面/<vid>.jpg
  data/收藏/封面/<vid>.jpg             （待确认，实际会扫描两种位置）

规则（已确认）：
  · 同一 vid 只保留一条（1,370 个重复），文件路径取先找到的
  · 2,605 条无文件的元数据丢弃
  · 来源标记 guanzhu / shoucang / both
  · 文件不移动

输出：index_service/index.db

用法：
  python build_index.py            # 增量（只重建表，重新扫描）
  python build_index.py --stats    # 只打印统计
"""
import os
import re
import sys
import io
import json
import sqlite3
import time
import argparse

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

ROOT = os.environ.get("DOUYIN_ROOT") or r"F:\新建文件夹"
DATA = os.path.join(ROOT, "data")
APPDATA = os.path.join(DATA, ".appdata")
DB = os.environ.get("DOUYIN_DB") or os.path.join(ROOT, "index_service", "index.db")


# ---------------------------------------------------------------- 读 js 数据
def load_js(path):
    """db_*.js 是 window.xxx=String.raw`{...}` 形式。"""
    with open(path, encoding="utf-8", errors="replace") as f:
        c = f.read()
    s = c.find("`") + 1
    e = c.rfind("`")
    if s <= 0 or e <= s:
        raise ValueError("无法解析: %s" % path)
    return json.loads(c[s:e])


# ---------------------------------------------------------------- 扫描文件
def scan_files():
    """返回 {vid: {"path":..., "group": "guanzhu"|"shoucang", "cover": path|None}}"""
    files = {}
    covers_by_vid = {}

    # 先扫封面（两种位置）
    for grp, key in (("关注", "guanzhu"), ("收藏", "shoucang")):
        gd = os.path.join(DATA, grp)
        if not os.path.isdir(gd):
            continue
        for dp, dn, fn in os.walk(gd):
            for f in fn:
                if f.lower().endswith(".jpg"):
                    vid = f[:-4]
                    if vid not in covers_by_vid:
                        covers_by_vid[vid] = os.path.join(dp, f)

    # 再扫视频
    for grp, key in (("关注", "guanzhu"), ("收藏", "shoucang")):
        gd = os.path.join(DATA, grp)
        if not os.path.isdir(gd):
            continue
        for dp, dn, fn in os.walk(gd):
            for f in fn:
                if not f.lower().endswith(".mp4"):
                    continue
                vid = f[:-4]
                full = os.path.join(dp, f)
                if vid in files:
                    # 已存在 → 标记 both
                    files[vid]["group"] = "both"
                    files[vid].setdefault("also", []).append(full)
                    continue
                files[vid] = {"path": full, "group": key}
    for vid, rec in files.items():
        rec["cover"] = covers_by_vid.get(vid)
    return files


# ---------------------------------------------------------------- 建库
def build(verbose=True):
    t0 = time.time()
    if verbose:
        print("读取元数据…", flush=True)
    dbv = load_js(os.path.join(APPDATA, "db_videos.js"))
    dbt = load_js(os.path.join(APPDATA, "db_texts.js"))
    dba = load_js(os.path.join(APPDATA, "db_authors.js"))

    if verbose:
        print("扫描文件…", flush=True)
    files = scan_files()

    if verbose:
        print("  元数据 %d / 文案 %d / 作者 %d / 文件 %d"
              % (len(dbv), len(dbt), len(dba), len(files)), flush=True)

    # 组装行
    rows = []
    missing_meta = 0
    for vid, rec in files.items():
        m = dbv.get(vid)
        if not m:
            missing_meta += 1
            continue
        aid = str(m.get("authorId") or "")
        an = dba.get(aid) or {}
        nicks = an.get("nicknames") or []
        author = (nicks[0] if nicks else "") or "未知作者"
        rows.append({
            "vid": vid,
            "authorId": aid,
            "author": author,
            "caption": (dbt.get(vid) or "").strip(),
            "digg": int(m.get("diggCount") or 0),
            "createTime": int(m.get("createTime") or 0),
            "videoPath": rec["path"],
            "coverPath": rec["cover"],
            "source": rec["group"],       # guanzhu / shoucang / both
            "followerCount": int(an.get("followerCount") or 0),
            "signature": (an.get("signature") or ""),
            "secUid": (an.get("secUid") or ""),
        })

    if verbose:
        print("  有效视频行 %d（丢 %d 个无元数据）" % (len(rows), missing_meta), flush=True)

    os.makedirs(os.path.dirname(DB), exist_ok=True)
    if os.path.exists(DB):
        os.remove(DB)
    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.executescript("""
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;

    CREATE TABLE videos (
        vid         TEXT PRIMARY KEY,
        authorId    TEXT NOT NULL,
        author      TEXT NOT NULL,
        caption     TEXT,
        digg        INTEGER DEFAULT 0,
        createTime  INTEGER DEFAULT 0,
        videoPath   TEXT NOT NULL,
        coverPath   TEXT,
        source      TEXT NOT NULL,
        srcWeight   REAL NOT NULL
    );
    CREATE INDEX idx_videos_author ON videos(authorId);
    CREATE INDEX idx_videos_time   ON videos(createTime DESC);
    CREATE INDEX idx_videos_digg   ON videos(digg DESC);

    CREATE TABLE authors (
        authorId      TEXT PRIMARY KEY,
        nickname      TEXT NOT NULL,
        followerCount INTEGER DEFAULT 0,
        signature     TEXT,
        secUid        TEXT,
        videoCount    INTEGER DEFAULT 0
    );
    CREATE INDEX idx_authors_name ON authors(nickname);
    """)

    # 来源权重：已确认 关注 ×0.5 / 收藏 ×1.0 / 两边都有 ×1.0
    W = {"guanzhu": 0.5, "shoucang": 1.0, "both": 1.0}
    cur.executemany(
        """INSERT OR REPLACE INTO videos
           (vid, authorId, author, caption, digg, createTime,
            videoPath, coverPath, source, srcWeight)
           VALUES (?,?,?,?,?,?,?,?,?,?)""",
        [(r["vid"], r["authorId"], r["author"], r["caption"], r["digg"],
          r["createTime"], r["videoPath"], r["coverPath"], r["source"],
          W.get(r["source"], 1.0)) for r in rows])

    # 作者表：4,724 个全进（含无视频者）
    acount = {}
    for r in rows:
        acount[r["authorId"]] = acount.get(r["authorId"], 0) + 1

    arows = []
    for aid, an in dba.items():
        aid = str(aid)
        nicks = an.get("nicknames") or []
        arows.append((
            aid,
            (nicks[0] if nicks else "") or "未知作者",
            int(an.get("followerCount") or 0),
            (an.get("signature") or ""),
            (an.get("secUid") or ""),
            acount.get(aid, 0),
        ))
    # 有视频但不在 db_authors 的作者（理论上为 0）
    for r in rows:
        if r["authorId"] not in dba:
            key = r["authorId"]
            if not any(x[0] == key for x in arows):
                arows.append((key, r["author"], 0, "", "", acount.get(key, 0)))

    cur.executemany(
        """INSERT OR REPLACE INTO authors
           (authorId, nickname, followerCount, signature, secUid, videoCount)
           VALUES (?,?,?,?,?,?)""", arows)

    con.commit()

    # 统计
    st = {}
    for k, q in (
        ("videos", "SELECT COUNT(*) FROM videos"),
        ("authors", "SELECT COUNT(*) FROM authors"),
        ("authors_with_video", "SELECT COUNT(*) FROM authors WHERE videoCount>0"),
        ("guanzhu", "SELECT COUNT(*) FROM videos WHERE source='guanzhu'"),
        ("shoucang", "SELECT COUNT(*) FROM videos WHERE source='shoucang'"),
        ("both", "SELECT COUNT(*) FROM videos WHERE source='both'"),
        ("no_cover", "SELECT COUNT(*) FROM videos WHERE coverPath IS NULL"),
        ("no_caption", "SELECT COUNT(*) FROM videos WHERE caption=''"),
    ):
        st[k] = cur.execute(q).fetchone()[0]

    con.close()
    el = time.time() - t0
    if verbose:
        print()
        print("=" * 56)
        for k, v in st.items():
            print("  %-20s %d" % (k, v))
        print("  用时 %.1f 秒" % el)
        print("  数据库 %s (%.1f MB)" % (DB, os.path.getsize(DB) / 1024**2))
    return st


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", action="store_true")
    a = ap.parse_args()
    st = build(verbose=True)
    print(json.dumps(st, ensure_ascii=False))
