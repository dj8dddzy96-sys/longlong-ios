# 龙龙 iOS 版 — 出 IPA 与自签安装

## 为什么不能直接给你现成 IPA

iOS 的 `.app` 二进制必须由 Apple 的 Swift 工具链 + iOS SDK 编译，而这套东西只有 macOS（Xcode）上有。
Windows 上没有任何办法把 Swift 源码编成能跑的 iOS 二进制——这不是配置问题，是工具链本身不存在。

所以流程是：**代码已经改好 → 用一台"云 Mac"编 → 下载 IPA → Windows 上自签装进手机**。

下面这条路全程免费，不需要自己有 Mac。

---

## 第一步：把源码推到一个 GitHub 仓库

1. 打开 https://github.com 注册 / 登录（免费）。
2. 右上角 `+` → **New repository**
   - Repository name：`pocketstash`
   - 选 **Private**
   - 不要勾 Add a README
   - 点 **Create repository**
3. 在新仓库页点 **uploading an existing file**（或 `Add file` → `Upload files`）
4. 把本压缩包解压后的**这些**拖进去：
   - `PocketStash/`（整个文件夹，里面的 .swift 和 Sites.json）
   - `project.yml`
   - `build-ipa.sh`
   - `.github/`（整个文件夹，里面有 workflows/build-ipa.yml）
   
   注意：Windows 资源管理器默认隐藏 `.github` 这种点开头的文件夹，要开「查看 → 隐藏的项目」才看得见，**别漏了它**。
5. 下面填个 commit message，点 **Commit changes**

## 第二步：让 GitHub 编出 IPA

1. 进仓库顶部 **Actions** 标签。
2. 第一次会有一条提示，点 **I understand my workflows, go ahead and enable them**。
3. 左边列表点 **Build Unsigned IPA** → 右边 **Run workflow** → 绿色按钮 **Run workflow**。
4. 等 5–8 分钟，任务变绿勾。
5. 点进这次运行，最下面 **Artifacts** → 下载 `PocketStash-unsigned-ipa.zip`。
6. 解压得到 **`PocketStash-unsigned.ipa`** ← 这个就是你的包。

失败了就看日志里第一个 `error:` 行，把它发我。

## 第三步：Windows 上自签装进 iPhone

需要的工具：**Sideloadly**（Windows 版，免费）
下载：https://sideloadly.io

1. Windows 装 **iTunes**（微软商店版即可）和 **iCloud**，装完各开一次并登录，让驱动就位。
2. iPhone 用数据线连电脑，手机上点「信任此电脑」。
3. 打开 Sideloadly：
   - **IPA**：选刚下载的 `PocketStash-unsigned.ipa`
   - **Apple ID**：填你自己的 Apple ID（普通账号就行，不用开发者账号）
   - 点 **Start**
4. 弹出 Apple ID 密码框，输入（只在本机用于换取签名证书，不会外传）。
5. 装完手机上会出现 App，但打不开——需要信任证书：
   **设置 → 通用 → VPN与设备管理 → 开发者App → 你的 Apple ID → 信任**
6. 打开 App 即可。

### 自签的两个硬限制

- **7 天过期**。到期 App 打不开，重新用 Sideloadly 装一次即可（数据不丢）。
- 免费 Apple ID 同时最多 **3 个**自签 App。

想永久不掉签只有两条路：加入 Apple 开发者计划（$99/年，1 年有效期），或者手机越狱后用 TrollStore（你的 iOS 版本决定可行性）。

---

## 这版 iOS App 做了什么

- **片源与安卓版逐条对齐**：`Sites.json` 27 条 = 安卓那 25 条（7 神秘站群 + 18 苹果CMS）+ Pornhub + OnlyFans。改源只改这个文件。
- 三种源后端（靠 `type` 字段自动选）：
  - `cms`：苹果CMS v10 接口直连，列表 / 搜索 / 直链提取（`vod_play_url` 里 `$` 后面那段）。
  - `html`：网页采集。随机 6 位子域 + `{host}` 线路池（18 条，缺 234）、标题 XOR128 解码、`/so.html` 走 POST 表单、详情页正则取直链。
  - `web`：隐藏 WKWebView 真渲染（Pornhub 有 JS 风控、OnlyFans 要登录态），取 `outerHTML` 后再解析。
- **播放与封面都带 Referer**：神秘站的 m3u8 和封面图缺详情页 Referer 一律 404，播放器（`AVURLAssetHTTPHeaderFieldsKey`）和封面请求都按条目补上。
- 播放用系统 AVPlayer，m3u8 原生支持，不用带 VLC 那几百 MB 的库。
- HTTP 层带 5 分钟内存缓存，翻页和来回切分类不重复发请求。
- 点过的条目自动进「历史」页，按分类归档，可以再点开播（Referer 一起存）。
- 右上角菜单：「登录网页源」（OnlyFans/Pornhub 用）、「刷新域名」（扫 sm 线路池）、「重载 Sites.json」。
- 零第三方依赖，编译只需 Xcode 自带框架。

### 两个源要用之前得知道

| 源 | 要求 |
|---|---|
| Pornhub | 首次点头像菜单 →「登录网页源」把 `age_verified=1` 之类过掉；国内网络要能出墙 |
| OnlyFans | 必须先在 App 内登录（菜单 →「登录网页源」），Cookie 存在 App 沙盒里；还必须在 `Sites.json` 里把 `creator` 填成具体博主名 |

## 目录说明

```
PocketStash/
├── project.yml                  # XcodeGen 工程描述（无外部依赖）
├── build-ipa.sh                 # 在任意 Mac 上一键出 IPA
├── .github/workflows/build-ipa.yml   # GitHub Actions 自动出 IPA
└── PocketStash/
    ├── PocketStashApp.swift     # 入口 + SwiftData 容器
    ├── ContentView.swift        # 抓取页（分类/搜索/翻页/播放）
    ├── LibraryView.swift        # 历史页
    ├── PlayerView.swift         # AVPlayer 播放（注入 Referer/UA）
    ├── Models.swift             # 数据模型 + 18 字段站点配置
    ├── Net.swift                # HTTP + 缓存 + POST 表单
    ├── Scraper.swift            # 三后端：cms / html / web
    ├── HtmlScraper.swift        # sm 站群池 + XOR128 + 标签解析
    ├── WebScraper.swift         # WKWebView 渲染器 + 登录页
    ├── ThumbImage.swift         # 带 Referer 取封面
    ├── HistoryStore.swift       # 历史写入
    ├── Sites.json               # 27 个片源
    └── Info.plist               # 允许 http、文件共享、中文名
```
