# PocketStash — iPhone / Android 自用版（免上架）

抓站点列表 → 下载 → 自动分类 → 片库播放。

- **iPhone 版**（`PocketStash/` Swift 工程）：Sideloadly 免费签名安装，7 天续一次
- **Android 版**（`android/` Kotlin 工程）：APK 直接装，**装一次永久有效**

## Android 版（最简单，APK 直接装）

云端会同时自动构建 Android APK（仓库里 `.github/workflows/build-apk.yml`）：

1. Actions 里第二个工作流 "Build APK" 跑完（约 5 分钟）→ Artifacts 下载 **PocketStash-apk**
2. 解压出 `app-debug.apk` → 微信/QQ/数据线传到手机
3. 手机上点开 APK → 弹出「未知来源」提示 → 允许 → 安装
4. 打开 PocketStash，抓取/片库/播放三页直接用，**没有 7 天限制**

- 改站点：只改 `android/app/src/main/assets/sites.json`（和 iPhone 版同一份格式）
- 视频存在 App 私有目录 `Android/data/com.yg.pocketstash/files/Movies/Videos/`

## 出 IPA（二选一）

### 路线 A：GitHub Actions 云端打包（无需 Mac）

1. 把本目录推到一个 GitHub 仓库（私有库即可，免费额度够跑几十次）：
   ```bash
   cd PocketStash
   git init && git add -A && git commit -m "init"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/pocketstash.git
   git push -u origin main
   ```
2. 仓库页 → **Actions** → 选中 "Build Unsigned IPA" → **Run workflow**（push 也会自动触发）。
3. 跑完（约 10–20 分钟，首次要下 VLC 框架较慢）→ 进入该次运行 → **Artifacts** → 下载 `PocketStash-unsigned-ipa`。
4. 解压得到 `PocketStash-unsigned.ipa`，发到手机（AirDrop 不行就用微信文件/iCloud 链接）。

### 路线 B：任意 Mac 一键脚本

```bash
./build-ipa.sh
# 产出 build/PocketStash-unsigned.ipa
```

## 安装到手机（未签名 IPA 通用两条路）

| 方式 | 有效期 | 版本要求 |
|---|---|---|
| **TrollStore**（推荐，装完永久） | 永久免签 | iOS 14.0–16.6.1 / 17.0 |
| **AltStore / SideStore**（自动重签） | 7 天自动续 | 任意 iOS 版本 |

- TrollStore：手机装好 TrollStore 后，用「文件」分享 `.ipa` → TrollStore → Install。
- AltStore：Mac/Windows 装 AltServer → 手机装 AltStore → AltStore 内 + 号导入 ipa（会用你的免费 Apple ID 签名）。

## 改站点 / 改分类

- **加站点**：只改 `PocketStash/Sites.json`，每站一条（名称、列表 URL 翻页 `{page}`、卡片 CSS 选择器、缩略图选择器），无需重写代码；改完重新出包。
- **改分类**：`PocketStash/Classifier.swift` 里 `bucket(siteTags:)` 的 `map` 表。

## 目录说明

```
project.yml                     XcodeGen 工程定义（依赖、签名关闭）
build-ipa.sh                    Mac 本地一键出包
.github/workflows/build-ipa.yml 云端自动出包
PocketStash/
  PocketStashApp.swift          入口
  Models.swift                  数据模型 + 站点配置加载
  Scraper.swift                 列表抓取 + 直链解析
  DownloadManager.swift         后台下载 + 入库
  Classifier.swift              系统露骨判定 + 标签分类
  ContentView.swift             抓取页
  LibraryView.swift             片库页（分类筛选）
  PlayerView.swift              VLC 播放器（全格式）
  Sites.json                    站点选择器配置
  Info.plist                    ATS 全放行 + 文件共享
```

## 已知边界

- 直链解析是通用兜底（og:video / `<source>` / .mp4 正则）；个别站点用加密流（m3u8 分片 + token），遇到就把站点名发我，我补专用解析器。
- iOS 后台下载会被系统调度，长时间锁屏可能暂停；大批量抓取建议前台挂着。
- 露骨判定用的是 iOS 17 系统框架，首次判定每部片约几十秒，入库后自动后台跑。
