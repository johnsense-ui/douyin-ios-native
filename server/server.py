# -*- coding: utf-8 -*-
"""抖音本地视频索引服务 —— 给 iOS App 用。

监听 127.0.0.1:8792，通过 Tailscale Serve 暴露为
  https://locvid-pc.tail83739b.ts.net:8444

接口：
  GET  /api2/feed?seed=&offset=&limit=&tab=recommend|following
  GET  /api2/author/<authorId>?offset=&limit=
  GET  /api2/authors?offset=&limit=&q=
  GET  /api2/search?q=&offset=&limit=
  GET  /api2/stats
  POST /api2/state           {"liked":{...},"saved":{...}}  增量
  GET  /api2/state
  GET  /thumbs/<vid>.jpg     封面缩略图（缺则回退原图）
  GET  /media/<path>         视频/封面源文件，支持 Range

设计要点：
  · 绝对 URL 由 Host 头自动拼
  · 推荐流用 seed 做确定性加权随机，同 seed 不重复
  · 来源权重：关注 ×0.5（已建在 srcWeight 列）
"""
import os
import sys
import io
import re
import json
import math
import time
import sqlite3
import random
import threading
import posixpath
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from email.utils import formatdate, parsedate_to_datetime

if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace",
                                  line_buffering=True)

ROOT = os.environ.get("DOUYIN_ROOT") or r"F:\新建文件夹"
DB = os.path.join(ROOT, "index_service", "index.db")
STATE_FILE = os.path.join(ROOT, "index_service", "state.json")
THUMB_DIR = os.path.join(ROOT, "index_service", "thumbs")
DATA = os.path.join(ROOT, "data")

HOST = os.environ.get("DOUYIN_HOST", "127.0.0.1")
PORT = int(os.environ.get("DOUYIN_PORT", "8792"))

HALF_LIFE_DAYS = 180.0     # 加权随机的时间半衰期
STATE_LOCK = threading.Lock()

MIME = {
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}


def log(*a):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), " ".join(str(x) for x in a)), flush=True)


# ---------------------------------------------------------------- 数据库
def db():
    con = sqlite3.connect(DB, timeout=10)
    con.row_factory = sqlite3.Row
    return con


# ---------------------------------------------------------------- 用户状态
def load_state():
    if not os.path.exists(STATE_FILE):
        return {"liked": {}, "saved": {}}
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            s = json.load(f)
        s.setdefault("liked", {})
        s.setdefault("saved", {})
        return s
    except Exception:
        return {"liked": {}, "saved": {}}


def save_state(s):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, STATE_FILE)


# ---------------------------------------------------------------- 加权随机
def build_order(seed, tab):
    """按 seed 生成确定性的加权随机顺序。返回 vid 列表。

    权重 = sqrt(digg+1) * exp(-ageDays/半衰期) * srcWeight
    用 seed 初始化 Random，对每条产生 r = U^(1/w) 并按降序取 —— 等价的加权采样，
    且同 seed 下顺序稳定、不重复。
    """
    con = db()
    if tab == "following":
        rows = con.execute(
            "SELECT vid, digg, createTime, srcWeight FROM videos").fetchall()
    else:
        rows = con.execute(
            "SELECT vid, digg, createTime, srcWeight FROM videos").fetchall()
    con.close()

    rng = random.Random(seed)
    now = time.time()
    order = []
    for r in rows:
        digg = r["digg"] or 0
        age = max(0.0, (now - (r["createTime"] or 0)) / 86400.0)
        tw = math.exp(-age / HALF_LIFE_DAYS)
        w = math.sqrt(digg + 1) * tw * (r["srcWeight"] or 1.0)
        # keys 法：u^(1/w)，w 越大越容易靠前
        u = rng.random() or 1e-9
        key = u ** (1.0 / max(w, 1e-6))
        order.append((key, r["vid"]))
    order.sort(reverse=True)
    return [v for _, v in order]


_ORDER_CACHE = {}
_ORDER_LOCK = threading.Lock()


def get_order(seed, tab):
    key = (seed, tab)
    with _ORDER_LOCK:
        it = _ORDER_CACHE.get(key)
        if it is not None:
            return it
        lst = build_order(seed, tab)
        if len(_ORDER_CACHE) > 8:
            _ORDER_CACHE.clear()
        _ORDER_CACHE[key] = lst
        return lst


# ---------------------------------------------------------------- 行 → JSON
_SAFE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/:"
            "\u4e00-\u9fff")


def _quote_path(p):
    """只转义 URL 里不安全的字符，保留中文和 /（更好读、更短）。"""
    out = []
    for ch in p:
        if ch in _SAFE or ("\u4e00" <= ch <= "\u9fff") or ("\u3000" <= ch <= "\u30ff"):
            out.append(ch)
        else:
            out.append(urllib.parse.quote(ch))
    return "".join(out)


def row_to_item(r, state, base):
    return {
        "vid": r["vid"],
        "caption": r["caption"] or "",
        "authorId": r["authorId"],
        "author": r["author"] or "未知作者",
        "digg": r["digg"] or 0,
        "createTime": r["createTime"] or 0,
        "video": base + "/media/" + _quote_path(r["videoPath"].replace(DATA, "").replace("\\", "/").lstrip("/")),
        "cover": (base + "/thumbs/" + r["vid"] + ".jpg"),
        "source": r["source"],
        "liked": bool(state["liked"].get(r["vid"])),
        "saved": bool(state["saved"].get(r["vid"])),
    }


def row_to_grid(r, base):
    keys = r.keys()
    return {
        "vid": r["vid"],
        "cover": base + "/thumbs/" + r["vid"] + ".jpg",
        "digg": r["digg"] or 0,
        "caption": r["caption"] or "",
        "authorId": r["authorId"] if "authorId" in keys else None,
        "author": r["author"] if "author" in keys else None,
    }


# ---------------------------------------------------------------- Handler
class Handler(BaseHTTPRequestHandler):
    server_version = "DouyinIndex/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    # ---------- 工具
    def base_url(self):
        host = self.headers.get("Host") or ("%s:%d" % (HOST, PORT))
        proto = self.headers.get("X-Forwarded-Proto") or "http"
        return "%s://%s" % (proto, host)

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # ---------- GET
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(u.path)
        q = urllib.parse.parse_qs(u.query or "")

        def g(k, d=None):
            v = q.get(k)
            return v[0] if v else d

        try:
            if path == "/api2/stats":
                con = db()
                c = con.cursor()
                st = {
                    "videos": c.execute("SELECT COUNT(*) FROM videos").fetchone()[0],
                    "authors": c.execute("SELECT COUNT(*) FROM authors").fetchone()[0],
                    "authorsWithVideo": c.execute(
                        "SELECT COUNT(*) FROM authors WHERE videoCount>0").fetchone()[0],
                }
                con.close()
                self._json(200, {"ok": True, **st})
                return

            if path == "/api2/feed":
                self.api_feed(g)
                return

            if path == "/api2/authors":
                self.api_authors(g)
                return

            if path == "/api2/search":
                self.api_search(g)
                return

            if path.startswith("/api2/author/"):
                self.api_author(path[len("/api2/author/"):], g)
                return

            if path == "/api2/state":
                self._json(200, {"ok": True, **load_state()})
                return

            if path.startswith("/thumbs/"):
                self.serve_thumb(path[len("/thumbs/"):])
                return

            if path.startswith("/media/"):
                self.serve_static(path[len("/media/"):])
                return

            if path in ("/", "/index.html"):
                self._json(200, {"ok": True, "service": "douyin index",
                                 "try": ["/api2/stats", "/api2/feed?limit=3"]})
                return

            self._json(404, {"ok": False, "error": "not found"})
        except BrokenPipeError:
            pass
        except Exception as e:
            log("ERROR", self.path, repr(e))
            try:
                self._json(500, {"ok": False, "error": str(e)})
            except Exception:
                pass

    # ---------- 接口实现
    def api_feed(self, g):
        try:
            off = max(0, int(g("offset", "0")))
            lim = min(30, max(1, int(g("limit", "12"))))
        except ValueError:
            off, lim = 0, 12
        tab = (g("tab") or "recommend").lower()
        seed = g("seed")
        if not seed:
            seed = str(int(time.time()))
        try:
            seed_i = int(seed)
        except ValueError:
            seed_i = int(seed) if seed.isdigit() else abs(hash(seed)) % (2**31)

        order = get_order(seed_i, tab)
        page = order[off:off + lim]
        state = load_state()
        base = self.base_url()

        items = []
        if page:
            con = db()
            placeholders = ",".join("?" * len(page))
            rows = con.execute(
                "SELECT * FROM videos WHERE vid IN (%s)" % placeholders, page).fetchall()
            con.close()
            by = {r["vid"]: r for r in rows}
            for vid in page:
                r = by.get(vid)
                if r:
                    items.append(row_to_item(r, state, base))

        self._json(200, {"ok": True, "seed": seed, "total": len(order),
                         "offset": off, "limit": lim, "items": items})

    def api_author(self, aid, g):
        aid = urllib.parse.unquote(aid)
        try:
            off = max(0, int(g("offset", "0")))
            lim = min(200, max(1, int(g("limit", "30"))))
        except ValueError:
            off, lim = 0, 30
        # full=1 → 返回 feed 格式（含 video 地址），供作者页直接播放
        full = (g("full") or "") == "1"
        con = db()
        a = con.execute("SELECT * FROM authors WHERE authorId=?", (aid,)).fetchone()
        tot = con.execute("SELECT COUNT(*) FROM videos WHERE authorId=?", (aid,)).fetchone()[0]
        rows = con.execute(
            "SELECT * FROM videos WHERE authorId=? ORDER BY createTime DESC LIMIT ? OFFSET ?",
            (aid, lim, off)).fetchall()
        con.close()
        base = self.base_url()
        if a:
            author = {
                "authorId": a["authorId"],
                "nickname": a["nickname"],
                "followerCount": a["followerCount"] or 0,
                "signature": a["signature"] or "",
                "videoCount": a["videoCount"] or 0,
                "avatar": None,
            }
        else:
            author = {"authorId": aid, "nickname": "未知作者", "followerCount": 0,
                      "signature": "", "videoCount": tot, "avatar": None}
        if full:
            state = load_state()
            its = [row_to_item(r, state, base) for r in rows]
        else:
            its = [row_to_grid(r, base) for r in rows]
        self._json(200, {"ok": True, "author": author, "total": tot,
                         "offset": off, "limit": lim, "full": full, "items": its})

    def api_authors(self, g):
        try:
            off = max(0, int(g("offset", "0")))
            lim = min(200, max(1, int(g("limit", "50"))))
        except ValueError:
            off, lim = 0, 50
        kw = (g("q") or "").strip()
        con = db()
        if kw:
            where, args = "WHERE nickname LIKE ?", ("%" + kw + "%",)
        else:
            where, args = "", ()
        tot = con.execute("SELECT COUNT(*) FROM authors " + where, args).fetchone()[0]
        rows = con.execute(
            "SELECT * FROM authors %s ORDER BY videoCount DESC, nickname LIMIT ? OFFSET ?" % where,
            args + (lim, off)).fetchall()
        con.close()
        self._json(200, {"ok": True, "total": tot, "offset": off, "limit": lim,
                         "items": [{
                             "authorId": r["authorId"],
                             "nickname": r["nickname"],
                             "followerCount": r["followerCount"] or 0,
                             "videoCount": r["videoCount"] or 0,
                             "signature": r["signature"] or "",
                             "avatar": None,
                         } for r in rows]})

    def api_search(self, g):
        kw = (g("q") or "").strip()
        try:
            va = min(50, max(1, int(g("authorLimit", "10"))))
            vv = min(50, max(1, int(g("videoLimit", "20"))))
            off = max(0, int(g("offset", "0")))
        except ValueError:
            va, vv, off = 10, 20, 0
        if not kw:
            self._json(200, {"ok": True, "q": "", "authors": [], "authorTotal": 0,
                             "videos": [], "videoTotal": 0})
            return
        like = "%" + kw + "%"
        con = db()
        atot = con.execute(
            "SELECT COUNT(*) FROM authors WHERE nickname LIKE ?", (like,)).fetchone()[0]
        arows = con.execute(
            "SELECT * FROM authors WHERE nickname LIKE ? ORDER BY videoCount DESC LIMIT ?",
            (like, va)).fetchall()
        vtot = con.execute(
            "SELECT COUNT(*) FROM videos WHERE caption LIKE ? OR author LIKE ?",
            (like, like)).fetchone()[0]
        vrows = con.execute(
            """SELECT * FROM videos WHERE caption LIKE ? OR author LIKE ?
               ORDER BY digg DESC LIMIT ? OFFSET ?""",
            (like, like, vv, off)).fetchall()
        con.close()
        base = self.base_url()
        state = load_state()
        self._json(200, {
            "ok": True, "q": kw,
            "authors": [{
                "authorId": r["authorId"], "nickname": r["nickname"],
                "followerCount": r["followerCount"] or 0,
                "videoCount": r["videoCount"] or 0,
                "signature": r["signature"] or "", "avatar": None,
            } for r in arows],
            "authorTotal": atot,
            "videos": [row_to_grid(r, base) for r in vrows],
            "videoTotal": vtot,
        })

    # ---------- 静态文件（支持 Range）
    def serve_thumb(self, name):
        name = os.path.basename(urllib.parse.unquote(name))
        vid = name.rsplit(".", 1)[0]
        # 优先缩略图
        for ext in (".jpg", ".jpeg", ".webp"):
            p = os.path.join(THUMB_DIR, vid + ext)
            if os.path.isfile(p):
                self.serve_file(p)
                return
        # 回退：原封面
        con = db()
        r = con.execute("SELECT coverPath FROM videos WHERE vid=?", (vid,)).fetchone()
        con.close()
        if r and r["coverPath"] and os.path.isfile(r["coverPath"]):
            self.serve_file(r["coverPath"])
            return
        self._json(404, {"ok": False, "error": "no cover"})

    def serve_static(self, rel):
        rel = posixpath.normpath(rel.replace("\\", "/")).lstrip("/")
        parts = [p for p in rel.split("/") if p and p not in (".", "..")]
        full = os.path.abspath(os.path.join(DATA, *parts))
        if not full.startswith(os.path.abspath(DATA)):
            self._json(403, {"ok": False, "error": "forbidden"})
            return
        if not os.path.isfile(full):
            self._json(404, {"ok": False, "error": "not found"})
            return
        self.serve_file(full)

    def serve_file(self, full):
        try:
            fsize = os.path.getsize(full)
        except OSError:
            self._json(404, {"ok": False, "error": "gone"})
            return
        ext = os.path.splitext(full)[1].lower()
        ctype = MIME.get(ext, "application/octet-stream")
        mtime = os.path.getmtime(full)
        etag = '"%x-%x"' % (int(mtime), fsize)

        # 条件请求
        inm = self.headers.get("If-None-Match")
        if inm and inm == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return

        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
            if m:
                s = m.group(1)
                e = m.group(2)
                if s == "" and e:
                    start = max(0, fsize - int(e))
                    end = fsize - 1
                else:
                    start = int(s or 0)
                    end = int(e) if e else fsize - 1
                end = min(end, fsize - 1)
                if start > end or start >= fsize:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % fsize)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                length = end - start + 1
                self.send_response(206)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, fsize))
                self.send_header("Content-Length", str(length))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("ETag", etag)
                self.send_header("Last-Modified", formatdate(mtime, usegmt=True))
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                if self.command == "HEAD":
                    return
                with open(full, "rb") as f:
                    f.seek(start)
                    left = length
                    while left > 0:
                        chunk = f.read(min(256 * 1024, left))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        left -= len(chunk)
                return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(fsize))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", formatdate(mtime, usegmt=True))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(full, "rb") as f:
            while True:
                chunk = f.read(256 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def do_HEAD(self):
        self.do_GET()

    # ---------- POST 状态
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if urllib.parse.unquote(u.path) != "/api2/state":
            self._json(404, {"ok": False, "error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b"{}"
            patch = json.loads(body.decode("utf-8"))
        except Exception as e:
            self._json(400, {"ok": False, "error": "bad json: %s" % e})
            return
        with STATE_LOCK:
            st = load_state()
            for key in ("liked", "saved"):
                if key in patch and isinstance(patch[key], dict):
                    for vid, v in patch[key].items():
                        if v:
                            st[key][vid] = 1
                        else:
                            st[key].pop(vid, None)
            save_state(st)
        self._json(200, {"ok": True, "liked": len(st["liked"]), "saved": len(st["saved"])})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,HEAD,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    if not os.path.exists(DB):
        log("数据库不存在，请先运行 build_index.py")
        return
    os.makedirs(THUMB_DIR, exist_ok=True)

    # AVPlayer 经常主动断开连接，这是正常现象，不要刷屏
    import socketserver
    _orig = socketserver.BaseServer.handle_error

    def _quiet(self, request, client_address):
        import sys as _s
        et = _s.exc_info()[0]
        if et and (issubclass(et, ConnectionResetError) or issubclass(et, BrokenPipeError)):
            return
        _orig(self, request, client_address)

    socketserver.BaseServer.handle_error = _quiet

    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    log("监听 http://%s:%d" % (HOST, PORT))
    log("接口: /api2/feed  /api2/author/<id>  /api2/authors  /api2/search  /api2/state")
    log("静态: /thumbs/<vid>.jpg  /media/<path> (Range)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("停止")


if __name__ == "__main__":
    main()
