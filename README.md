# 抖珍藏 · iOS 原生

本地抖音视频库的 iOS 客户端。竖屏上下滑，抖音式交互。

## 组成

```
├── swift/                      iOS App（SwiftUI + AVFoundation，iOS 18+）
│   ├── DouyinLocal.xcodeproj
│   └── DouyinLocal/
│       ├── App/                入口 + 首次连接页
│       ├── Models/             数据结构（对应服务端 JSON）
│       ├── Net/                APIClient
│       ├── Feed/               推荐流 + 原生分页容器
│       ├── Player/             播放器池（3 个 AVPlayer，流畅度核心）
│       ├── Author/             作者主页 + 作品播放
│       ├── Search/             搜索（作者 + 视频两块）
│       ├── State/              点赞收藏
│       └── UI/                 主题 / 双击爱心 / 图片缓存
└── server/                     本地索引服务（Python）
    ├── build_index.py          扫描 → SQLite
    └── server.py               HTTP 接口 + Range 静态文件
```

## 服务端

```bash
# 1. 建索引（约 2 秒，生成 index.db）
python server/build_index.py

# 2. 起服务
python server/server.py        # 127.0.0.1:8792
```

接口：

| 路径 | 说明 |
|---|---|
| `GET /api2/stats` | 统计 |
| `GET /api2/feed?seed=&offset=&limit=12&tab=recommend` | 推荐流（加权随机） |
| `GET /api2/author/<id>?full=1` | 作者信息 + 作品（full=1 含视频地址） |
| `GET /api2/authors?offset=&limit=` | 作者列表（4,724 个） |
| `GET /api2/search?q=` | 搜索，返回 authors + videos 两块 |
| `GET /api2/state` · `POST /api2/state` | 点赞/收藏（增量） |
| `GET /thumbs/<vid>.jpg` | 封面 |
| `GET /media/<path>` | 视频/封面源文件，**支持 Range** |

### Tailscale 映射

手机端地址：`https://locvid-pc.tail83739b.ts.net:8444`

```bash
tailscale serve --bg --https=8444 http://127.0.0.1:8792
```

> App 首次启动会提示填写该地址，连上后自动记住。

## iOS 构建（无 Mac）

推送到 `main` 后，GitHub Actions 自动用 macOS runner 编译并产出 **unsigned IPA**：

1. 仓库 → **Actions** → `ios-build` → 下载 `DouyinLocal-ipa`
2. 用自签工具（AltStore / Sideloadly 等）安装到 iPhone
3. 免费 Apple ID 签名 **7 天有效**，到期重新签

## 数据说明

- 视频总数 **30,396**（去重后），物理文件 31,766
- 作者 **4,724** 个，其中 **4,545** 个有视频
- 来源：`关注`（按作者下载）与 `收藏`（按收藏下载，平铺）
- 同一视频两边都有时只显示一条

## 已知限制

- 评论功能未做（本地无评论数据）
- 原声/音频页未做
- 头像用昵称首字占位
