# LinkPool

一个原生、轻量的 macOS 工具：把多条校园网上行链路（多个账号 / 多个网口 / 多个 IP）聚合成一个本地代理，让下载器、浏览器按连接自动分流，从而叠加带宽。

- 纯 Swift + SwiftUI，无第三方依赖，安装包 < 5 MB
- 菜单栏常驻 + 独立控制面板
- 本地 SOCKS5 / HTTP CONNECT 代理（默认 `127.0.0.1:7890`）
- 账号密码存 Keychain，配置文件为可读 JSON
- 显式操作才注销，绝不自动注销已有会话

## 先理解一个硬限制

校园网的一次认证 = 一个「IP + 账号」的会话。DHCP 默认只给一张网卡一个地址，但可以手动加 IP 别名来承载第二个会话；所以：

- 只有一张 Wi-Fi 网卡时，无法凭空变出多个会话。所谓「像 Clash 一样的虚拟网卡」（utun/TUN）是三层设备，没有 MAC、不参与 DHCP，校园网看不到它。它能做的是**透明分流层**（把系统流量按连接分到不同出口），但不能增加会话数。
- 真正的多会话来源只有两类：
  1. **多个真实上行**：Wi-Fi + USB 网卡 / 墙上网口 / 手机 USB 共享（每个口一个账号）。
  2. **同一网卡上的多个 IP 别名**（「多拨」）：`ifconfig en0 alias 10.10.55.240/21`。是否可用取决于学校是否绑定 IP-MAC；被限制时登录后会立刻掉线。工具里提供了实验入口，需要管理员权限。
- 单条 TCP 连接无法跨账号叠加；叠加发生在**多连接**层面（浏览器并发、下载器多线程、Range 分段）。因此代理按「连接」选路，默认关闭粘滞。

实测记录（2026-11-26，本校 Wi-Fi、同一张 en0）：

- `en0` 加别名 `10.10.55.250` 后，`tls0228@.234` 与 `tls0338@.250` **可以同时在线**，说明华为 AC 按 IP 识别会话，同一 MAC 下允许多会话。
- 通过本地代理发起 6 次请求，3 次走 `.234`、3 次走 `.250`，出口公网 IP 分别为 `120.197.158.106` / `120.197.158.117`，按连接分流有效。
- 但单账号 6 线程与双账号 3+3 线程的合计吞吐都约 **10 Mbps**（Cloudflare 与 USTC 镜像交叉验证）。这说明该 Wi-Fi/AP 对**每个终端 MAC** 有约 10 Mbps 的共享上限，别名不能突破它。别名适合「多账号同时在线、分摊配额/并发」，不能在这张网卡上提速。
- 要真正叠加带宽，需要**第二块物理网卡**（USB Wi-Fi / USB 以太网）接入另一个 AP 或墙上网口，让两个终端各自拥有独立 MAC 与限速桶。

## 功能

| 模块 | 说明 |
| --- | --- |
| 账号 | 增删改，密码写入 Keychain，支持备注与启用/停用 |
| 链路 | 自动发现网卡与地址；可添加物理链路或 IP 别名；绑定账号、权重、自动登录开关 |
| 会话 | 周期检查在线状态，指数退避重试，失败不影响其它链路；登录请求绑定源地址，保证会话落在正确的 IP 上；物理链路会跟随 DHCP 续约自动更新源地址 |
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

`swift test --disable-sandbox` 运行单元测试（Srun / 华为 RC4 加密向量、分流策略，共 17 项）。

## 使用

1. 打开 App，首次会显示控制面板；关闭窗口后留在菜单栏。
2. 「账号」添加校园网账号（密码存 Keychain）。
3. 「链路」把当前网卡地址添加为链路，并绑定账号。
4. 「代理」启动，得到 `127.0.0.1:7890`。默认会同时勾选「同时设置 macOS 系统代理」，启动时代入、停止时**原样恢复**，所以 Safari / Chrome 无需手动配置。若取消勾选，则自己把应用代理指向：
   - SOCKS5：`socks5h://127.0.0.1:7890`
   - HTTP：`http://127.0.0.1:7890`

   > 系统代理开关会在修改前备份当前 Wi-Fi 代理配置（主机、端口、状态、绕过列表），停止代理或退出应用时恢复。若应用被强制结束导致浏览器断网，运行 `linkpoolctl sysproxy off` 即可恢复。
5. 多链路时，下载器的多线程/Range 分段会自动分散到各出口。单个大文件想跑满，用多连接下载器，例如：

   ```bash
   aria2c -x16 -s16 -k1M --all-proxy=socks5h://127.0.0.1:7890 https://example.com/big.iso
   ```

   浏览器自身会并发多个连接；但单连接下载（例如部分网盘直链）只能用到一条链路。

命令行：

```bash
.build/debug/linkpoolctl interfaces
.build/debug/linkpoolctl status
.build/debug/linkpoolctl serve          # 前台跑代理，Ctrl-C 退出
.build/debug/linkpoolctl login "Wi-Fi 主链路"
.build/debug/linkpoolctl secret 主账号      # 只检查密码是否在钥匙串中，不显示密码
.build/debug/linkpoolctl sysproxy off    # 强制恢复系统代理（崩溃/强退后救援）
```

配置目录：`~/Library/Application Support/LinkPool/config.json`
日志：`~/Library/Logs/LinkPool.log`（2 MB 轮转）
调试时可设 `LINKPOOL_HOME=/tmp/xxx` 隔离配置。

## 门户协议

内置两种适配器，可在「设置 → 门户 → 协议」切换：

| 协议 | 说明 |
| --- | --- |
| **华为 AC（ac_portal）** | 默认。`POST /ac_portal/login.php`，字段 `opr=pwdLogin`、`userName`、`pwd`、`auth_tag`、`rememberPwd`；`pwd` 是「毫秒时间戳为密钥的 RC4」十六进制串，`auth_tag` 就是该时间戳。请求按源地址绑定，AC 依据 TCP 源 IP 建立会话。 |
| **深澜 Srun 4.x** | `/cgi-bin/get_challenge` + `/cgi-bin/srun_portal`，HMAC-MD5 + XXTEA（`{SRBX1}` 自定义 base64），已用公开实现的向量逐字节验证。 |

在线判定不依赖门户页面：先请求 `edge-http.microsoft.com/captiveportal/generate_204`，204 即在线；被 302 到 `ac_portal` 即未认证。DNS 被拦截时回退到门户根路径，按其跳转目标（`/homepage/...` 或 `/ac_portal/...`）判断。

这台学校的 `http://4.3.2.1` 在已登录状态下只暴露 Srun 自助服务；登录页 `/ac_portal/20231023153358/pc.html` 只在未认证 IP 上由 AC 下发。华为适配器是按该页面的 `logic_new.js` 实现的。真实登录建议用**额外的测试账号 + 另一个源 IP**（例如多拨别名或第二个网口）验证，这样不需要断开当前正在使用的会话。

> 钥匙串说明：应用以 ad-hoc 签名分发，重新构建后签名哈希会变化，macOS 可能拒绝旧的钥匙串条目。应用会自动回退到系统 `security` 命令读取/写入，因此重编译不会丢密码；若仍失败，重新保存一次账号密码即可。

若门户接口不可用，可在「代理」里打开**允许未验证链路**：代理仍会经该链路转发，但无法确认账号是否在线，仅建议排障时使用。

## 目录

```
Sources/
  LinkPoolCore/          # 与 UI 无关的核心库
    Models/              # 数据模型与配置
    Network/             # 网卡、套接字、HTTP 客户端
    Portal/              # 华为 AC / Srun 协议与加密
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
