# SideStore 装龙龙 iOS 版

SideStore 本身不会编译源码，它只吃**已经编好的 IPA**。所以顺序还是：

```
源码 → 云 Mac 编出 IPA → SideStore 签名安装
```

第一步（出 IPA）看 `IPA-构建说明.md`。下面是从拿到 IPA 开始的全部操作。

---

## 前提自检（SideStore 已经装好就基本都过了）

| 项 | 要求 |
|---|---|
| iOS 版本 | 14.0 以上（你这台没问题） |
| 配对文件 | SideStore 首次安装时已导入，装好后不用再管 |
| Anisette 服务器 | SideStore 设置里保持默认 `https://ani.sidestore.io` |
| WireGuard | 「设置 → SideStore」那条本地 VPN 配置要**保持启用**，SideStore 靠它跟本机通信 |
| 后台 App 刷新 | 系统设置里对 SideStore 打开，否则 7 天续签跑不起来 |
| 免费 Apple ID | 同时最多 3 个自签 App，超过就删一个 |

## 一、把 IPA 弄到手机上

**做法 1：电脑下载再传（最稳）**

1. 电脑上从 GitHub Actions 下载 `PocketStash-unsigned-ipa.zip`，解压出 `PocketStash-unsigned.ipa`。
2. 传到 iPhone 的任意方式都行：微信「文件传输助手」、iCloud 云盘、QQ、数据线（爱思/iMazing）。
3. 在 iPhone 上把它**存进「文件」App**（微信里点开文件 → 右上角 → 存储到「文件」）。

**做法 2：手机直接装（如果仓库设成 Public）**

GitHub Actions 跑完会在 Releases 里挂一个 `build-N` 的版本，直链形如：

```
https://github.com/你的用户名/pocketstash/releases/download/build-1/PocketStash-unsigned.ipa
```

在 iPhone 的 Safari 里访问下面这行（把 URL 换成你的直链），会直接唤起 SideStore 安装：

```
sidestore://install?url=https://github.com/你的用户名/pocketstash/releases/download/build-1/PocketStash-unsigned.ipa
```

私有仓库这条路走不通（下载要登录），用做法 1。

## 二、SideStore 里安装

1. 打开 **SideStore**。
2. 底部 **Apps** 标签 → 右上角 **+**。
3. 系统弹出文件选择器 → 选「文件」里的 `PocketStash-unsigned.ipa`。
4. 弹出登录框：填你的 **Apple ID + 密码**（用于换取免费签名证书，只走 Apple 官方接口）。
   - 有双重认证的话，会再要一次 6 位验证码。
5. 等进度条走完，回桌面就有「龙龙免费看片」了。
6. **首次打开失败是正常的**，去信任证书：
   **设置 → 通用 → VPN与设备管理 → 开发者App → 你的 Apple ID → 信任**

## 三、7 天续签

免费签名 7 天到期。SideStore 的设计是在**快要过期前自动续**，但必须满足：

- SideStore 的 WireGuard 配置一直开着；
- 系统设置里 SideStore 的后台 App 刷新打开；
- 每隔几天至少让 SideStore 在后台跑一次（插电 + 连 WiFi 的夜里最容易成功）；
- 别手动杀 SideStore 进程。

不确定有没有续上，就隔三五天打开一次 SideStore → Apps → 看龙龙那条右边的剩余天数，点一下手动刷新也行。刷新时**不要删 App**，数据保留。

## 四、装不上时对症

| 现象 | 原因 / 处理 |
|---|---|
| 选完 IPA 闪退 | 配对文件失效，SideStore 设置里重新导入配对文件 |
| `Unable to install` / `Aseprite` 类报错 | 免费 Apple ID 的 3 个名额满了，删掉一个用不上的自签 App |
| 卡在 `Signing...` 很久 | Anisette 服务器抽风，设置里换成 `https://ani.sidestore.io` 或等一会儿重试 |
| 打开就闪退、没图标 | 证书没信任，走上面第 6 步 |
| 提示 App 已存在但版本没变 | SideStore 里先长按删掉旧的，再装新的（历史记录会丢，片源不影响） |
| 提示 bundle id 冲突 | 说明之前用别的 Apple ID 装过，删干净再装 |

## 五、这版 App 的样子

- 两个标签页：**抓取**（分类 / 搜索 / 翻页 / 点击播放）、**历史**（点过的自动记录，按分类归堆）
- 片源和安卓版共用同一份 `Sites.json`，11 个苹果CMS 源，接口直出 m3u8
- 播放走系统 AVPlayer，不依赖 VLC
- 零第三方依赖，构建稳定
