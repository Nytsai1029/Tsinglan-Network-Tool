# LinkPool

一个原生、轻量的 macOS 工具：把多条校园网上行链路（多个账号 / 多个网口 / 多个 IP）聚合成一个本地代理，让下载器、浏览器按连接自动分流，从而叠加带宽。

- 纯 Swift + SwiftUI，无第三方依赖，安装包 < 5 MB
- 菜单栏常驻 + 独立控制面板
- 本地 SOCKS5 / HTTP CONNECT 代理（默认 `127.0.0.1:7890`）
- 账号密码存 Keychain，配置文件为可读 JSON
- 显式操作才注销，绝不自动注销已有会话

## 先理解一个硬限制

校园网的一次认证 = 一个「IP + 账号」的会话。**一条物理链路在同一时刻只能有一个 DHCP 地址**，所以：

- 只有一张 Wi-Fi 网卡时，无法凭空变出多个会话。所谓「像 Clash 一样的虚拟网卡」（utun/TUN）是三层设备，没有 MAC、不参与 DHCP，校园网看不到它。它能做的是**透明分流层**（把系统流量按连接分到不同出口），但不能增加会话数。
- 真正的多会话来源只有两类：
  1. **多个真实上行**：Wi-Fi + USB 网卡 / 墙上网口 / 手机 USB 共享（每个口一个账号）。
  2. **同一网卡上的多个 IP 别名**（「多拨」）：`ifconfig en0 alias 10.10.55.240/21`。是否可用取决于学校是否绑定 IP-MAC；被限制时登录后会立刻掉线。工具里提供了实验入口，需要管理员权限。
- 单条 TCP 连接无法跨账号叠加；叠加发生在**多连接**层面（浏览器并发、下载器多线程、Range 分段）。因此代理按「连接」选路，默认关闭粘滞。

## 功能

| 模块 | 说明 |
| --- | --- |
| 账号 | 增删改，密码写入 Keychain，支持备注与启用/停用 |
| 链路 | 自动发现网卡与地址；可添加物理链路或 IP 别名；绑定账号、权重、自动登录开关 |
| 会话 | 周期检查在线状态，指数退避重试，失败不影响其它链路；登录请求绑定源地址，保证会话落在正确的 IP 上 |
| 代理 | SOCKS5（CONNECT）+ HTTP（CONNECT / 绝对 URI）；轮询 / 最少连接 / 加权随机；可选按域名粘滞 |
| 观测 | 每条链路实时速率、累计流量、活动连接数；菜单栏显示总速率；内置日志查看器 |
| 诊断 | `linkpoolctl` 命令行可查网卡、查状态、登录/注销单条链路、前台跑代理 |

## 构建

要求 macOS 14+、Xcode 26（Swift 6.2）。

```bash
# 开发构建（沙箱环境需要 --disable-sandbox）
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clangcache"
swift build --disable-sandbox

# 打包 .app（含图标、Info.plist、临时签名）
./scripts/build-app.sh release
open dist/LinkPool.app
```

`swift test --disable-sandbox` 运行单元测试（Srun 加密向量、分流策略）。

## 使用

1. 打开 App，首次会显示控制面板；关闭窗口后留在菜单栏。
2. 「账号」添加校园网账号（密码存 Keychain）。
3. 「链路」把当前网卡地址添加为链路，并绑定账号。
4. 「代理」启动，得到 `127.0.0.1:7890`。把下载器/浏览器代理指向它：
   - SOCKS5：`socks5h://127.0.0.1:7890`
   - HTTP：`http://127.0.0.1:7890`
5. 多链路时，下载器的多线程/Range 分段会自动分散到各出口。

命令行：

```bash
.build/debug/linkpoolctl interfaces
.build/debug/linkpoolctl status
.build/debug/linkpoolctl serve          # 前台跑代理，Ctrl-C 退出
.build/debug/linkpoolctl login "Wi-Fi 主链路"
```

配置目录：`~/Library/Application Support/LinkPool/config.json`
日志：`~/Library/Logs/LinkPool.log`（2 MB 轮转）
调试时可设 `LINKPOOL_HOME=/tmp/xxx` 隔离配置。

## 门户适配现状（重要）

内置的是**标准 Srun 4.0** 协议（`/cgi-bin/get_challenge`、`/cgi-bin/srun_portal`、`/cgi-bin/rad_user_info`），并已用公开实现做过逐字节向量验证。

但本机实测 `http://4.3.2.1` 只暴露了 Srun **自助服务**（`/homepage/index.html`、`/homepage/info.php`），标准接口全部返回 404。也就是说：这台设备上的登录页由 AC 在**未认证时**下发，当前已登录的 IP 拿不到该页面，无法从本机推断真实登录接口。

因此自动登录需要一次「登录页抓包」来适配：

1. 用手机连校园 Wi-Fi（不登录），打开浏览器，记录被跳转到的完整 URL 与页面截图；或
2. 在电脑上退出登录后，用浏览器开发者工具抓一次登录请求（URL、方法、表单字段）。

拿到后只需新增一个 Portal 适配器（`Sources/LinkPoolCore/Portal/`），上层会话/代理无需改动。

在门户接口不可用时，可在「代理」里打开**允许未验证链路**：代理仍会经该链路转发，但无法确认账号是否在线，仅建议单链路排障使用。

## 目录

```
Sources/
  LinkPoolCore/          # 与 UI 无关的核心库
    Models/              # 数据模型与配置
    Network/             # 网卡、套接字、HTTP 客户端
    Portal/              # Srun 协议与加密
    Session/             # 会话生命周期
    Proxy/               # SOCKS5/HTTP 代理、分流、指标
    Support/             # 配置、Keychain、日志、路径、Shell
  LinkPoolApp/           # SwiftUI 菜单栏 App
  linkpoolctl/           # 命令行
Tests/LinkPoolCoreTests/
packaging/               # Info.plist、图标
scripts/build-app.sh
```

## 安全与边界

- 只使用你拥有或获得明确授权的账号；工具不做任何绕过认证、伪造 MAC 或攻击网络的行为。
- 不自动注销：只有你点「注销」或 CLI 显式调用才会发注销请求。
- 密码只存 Keychain；配置 JSON 不含明文密码。
- 所有流量仍受学校网关的策略与计费约束。
