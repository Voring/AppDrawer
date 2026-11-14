# AppDrawer

roothide（多巴胺隐根）越狱插件：`appdrawer://` 唤出一个**半屏 App 抽屉**，顶部搜索框可搜已装 App（支持拼音/首字母/Bundle ID），点一下交给 **ScreenCore** 以浮窗打开。

- 包名：`com.voring.appdrawer`
- 支持：iOS 16.0+，arm64e，roothide 隐根（Dopamine）
- 构建：`macos-15-intel` + roothide Theos + iPhoneOS16.5.sdk（GitHub Actions 自动出包）

## 功能

- 半屏毛玻璃面板（默认 55% 屏高、顶部两角 28pt 圆角），从顶部弹入，点面板外部即收起
- 顶部 `UISearchBar`，实时过滤：原名、全拼、拼音首字母、去空格全拼、Bundle ID 都可命中
- 4 列 `UICollectionView` 图标网格（可配 3～6 列），图标在后台队列异步读取并缓存
- 点击图标后收起面板，再交给系统 LaunchServices 打开 App；ScreenCore 已接管系统跳转，所以正常会以浮窗形式呈现（详见下文“与 ScreenCore 的配合”）
- URL scheme 可静默唤起（不会先閃一下代理 App）

## 安装

1. 从 Releases 下载 `com.voring.appdrawer_*_iphoneos-arm64e.deb`
2. 用 Sileo / Zebra 安装，或 `dpkg -i`
3. 安装后自动执行 `uicache -p /Applications/AppDrawerURL.app` 注册 scheme（roothide 下会自动尝试 `/var/jb/usr/bin/uicache`）

依赖：`mobilesubstrate`；推荐同时安装 `com.susudear.screencore`（不装也能用，只是没有浮窗效果）。

## URL Scheme

| URL | 行为 |
| --- | --- |
| `appdrawer://show` | 唤出面板 |
| `appdrawer://show?q=微信` | 唤出面板并填入搜索词 |
| `appdrawer://search?q=wx` | 同上 |
| `appdrawer://close` | 收起面板 |
| `appdrawer://open?bundle=com.apple.mobilesafari` | 不开面板，直接打开指定 App |
| `appdrawer://open/com.apple.mobilesafari` | 同上（path 写法） |

用法举例：快捷指令“打开 URL”、Kildong / 手势插件、终端 `open appdrawer://show?q=qq`。

## 偏好设置

直接编辑 `/var/mobile/Library/Preferences/com.voring.appdrawer.plist`，改完 re-spring 或重新唤起面板即生效：

```xml
<dict>
    <key>Columns</key>              <integer>4</integer>     <!-- 3 ~ 6 -->
    <key>PanelHeightPercent</key>   <real>0.55</real>        <!-- 0.35 ~ 0.85，>1 视作百分数 -->
    <key>PanelCornerRadius</key>    <real>28</real>
    <key>ShowSystemApps</key>       <true/>
    <key>ForceScreenCoreFloating</key><false/>             <!-- 优先直连 ScreenCore 私有浮窗接口 -->
    <key>BlurStyle</key>            <integer>0</integer>     <!-- 0 自适应 / 1 浅 / 2 深 / 3、4 Chrome -->
</dict>
```

## 与 ScreenCore 的配合

ScreenCore 2.0.5 解包后可以看到：`ScreenCore.dylib` 注入 `com.apple.springboard`，`ScreenCoreHelper.dylib` 注入 `com.apple.UIKit`，并提供 `SCFloatingSceneManager`、`SCFloatingDockManager`、`SCExternalLinkCoordinator`、`SCApplicationTarget`，以及 `sc_openSplitForBundleIdentifier:` / `sc_openSplitForBundleIdentifier:presentationSourceRect:` / `sc_openTargetIdentifier:` 等方法，同时开着 `splitSystemURLRoutingEnabled` / `splitExternalLinkRoutingEnabled` 两个开关。

因此 AppDrawer 的打开顺序是：

1. `LSApplicationWorkspace -openApplicationWithBundleIdentifier:`（主路径）—— 与聚焦搜索同一条链路，ScreenCore 会把它转成浮窗
2. ScreenCore 私有 selector（`sc_openSplitForBundleIdentifier:` / `sc_openTargetIdentifier:`），对 `SBIconController` / `SCFloatingSceneManager` / `SCExternalLinkCoordinator` / `SBApplicationController` 逐个探测 shared 实例，按返回值 encoding 安全派发
3. `SBSLaunchApplicationWithIdentifier`（`dlsym` 方式，最后兜底）

把 `ForceScreenCoreFloating` 设为 `true` 可把第 2 步提到最前，适合 ScreenCore 版本变化后调试。

## 工程结构

```
AppDrawer/
├── Makefile                     # ARCHS=arm64e, TARGET=iphone:clang:16.5:16.0, roothide scheme
├── control
├── Core/                        # 本体 tweak，注入 com.apple.springboard
│   ├── AppDrawer.plist          # MobileSubstrate 过滤器
│   ├── ADEntry.m                # 构造器：装钩子 + 预热应用列表
│   ├── ADPanelController.m      # 高层级 UIWindow、scheme 指令路由、Darwin 通知
│   ├── ADPanelViewController.m  # 半屏毛玻璃面板 + 搜索 + 网格
│   ├── ADAppCatalog.m           # LSApplicationWorkspace 枚举、隐藏 App 过滤、排序
│   ├── ADAppInfo.m              # 图标读取 + 拼音检索串（含 NSCache）
│   ├── ADLauncher.m             # LaunchServices / ScreenCore / SBS 三级打开
│   ├── ADURLDispatchHooks.m     # SpringBoard / FBSystemService / LSApplicationWorkspace 钩子
│   └── ADPrefs.m
├── Shared/URLScheme/            # 两端共用的 scheme 常量 + 文件/Darwin 通知通道
├── Handler/                     # 极小隐藏 App，只用来让 LaunchServices 认领 appdrawer://
└── layout/DEBIAN/               # postinst 刷新 uicache，postrm 清理
```

URL 请求通道使用真实路径 `/var/mobile/Library/Preferences/com.voring.appdrawer`（**刻意不用 `jbroot()`**），所以独立 App 不链接 libroothide。

## 构建

CI（`.github/workflows/build.yml`，`macos-15-intel`）：

```bash
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide ARCHS=arm64e \
  TARGET=iphone:clang:16.5:16.0
```

本地 Linux 交叉编译（仅能出 arm64 验证包，arm64e 交给 macOS）：

```bash
export THEOS=/path/to/theos   # roothide fork
export PATH="$THEOS/toolchain/linux/iphone/bin:$PATH"
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide ARCHS=arm64 \
  ADDITIONAL_LDFLAGS="-fuse-ld=lld -Wl,-undefined,dynamic_lookup"
```

> roothide 的 Theos fork 会把包的 `Architecture` 强制成 `iphoneos-arm64e`，所以 `control` 里也写的是 `iphoneos-arm64e`。

## 已知限制

- 面板 `windowLevel = 10000001`（高于控制中心），会盖住通知中心等系统 UI
- ScreenCore 私有接口是否命中取决于其版本；未命中时走 LaunchServices，效果一般也是浮窗
- 依赖 `LSApplicationProxy` / `iconDataForVariant:` 等私有 API，仅适用于越狱环境
