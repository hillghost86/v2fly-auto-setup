# v2fly-auto-setup.sh

在 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 或 CentOS Stream 9 上，通过 Docker 管理多个 **V2Fly v5** 节点，使用 **VMess + WebSocket + TLS**。每个节点独立运行一个 V2Fly 容器，支持本机直出和远端中转。

这是采用多节点架构的大版本：只管理本版本创建的节点，不读取、接管或迁移旧单节点配置，不提供旧单节点菜单。部署目录固定为 `/root/v2fly-stack`；不会自动删除旧目录或旧服务。旧服务占用端口时，需要自行处理冲突，或使用已有 Nginx 入口。

## 线路与入口

例如在韩国服务器创建两个节点：

| 客户端节点 | 连接线路 | 网站看到的出口 |
| --- | --- | --- |
| 韩国直出 | Shadowrocket → 韩国 → 网站 | 韩国服务器 |
| 韩国转日本 | Shadowrocket → 韩国 → 日本 → 网站 | 日本服务器 |

分别导入两条 `vmess://` 链接，在客户端切换即可。规则模式下被设置为直连的请求不会经过节点。中转出口支持 VMess + WebSocket + TLS，可导入远端链接或手动输入连接参数；中转失败不会自动改为本机直出。

每个节点有独立的数字编号、名称、UUID、WebSocket 路径、本地端口及出口配置。编号自动递增，删除后不重新使用。HTTPS 入口可以共用域名和 443，通过不同路径分发。

| 入口 | 容器与证书 | 用户操作 |
| --- | --- | --- |
| Caddy | 各节点独立容器，共享 Caddy 入口及证书 | 域名解析到服务器，并放行 TCP 80/443 |
| 已有 Nginx / 宝塔 | 各节点端口绑定回环地址，证书由现有站点管理 | 将脚本输出的路径转发片段加入 HTTPS 站点 |

同一服务器上的脚本节点使用同一种入口管理方式，避免 Caddy 与 Nginx 争用 80/443。入口菜单只列出本版本登记的域名；域名已经解析并不代表存在可复用入口。

## 开始使用

需要 root 权限、systemd，以及解析到服务器的域名。先执行 `sudo -i`，然后运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/main/v2fly-auto-setup.sh)
```

主菜单：

```text
1) 新增节点
2) 管理节点
3) 所有节点状态
4) 更新指定节点
5) 删除节点
6) 初始化环境
7) 更新共享 Caddy
0) 退出
```

可直接选择「新增节点」，整个流程分为五个阶段：

1. **只读检查**：检查系统、依赖、Docker、内存 / Swap 和二维码工具，不安装或修改配置。
2. **填写信息**：依次填写节点类型、名称、HTTPS 入口、高级设置和中转参数。每一步有短分界线、编号与标题，同组字段之间留空行。
3. **汇总确认**：查看节点配置及需要执行的环境准备项目，提前选择 Swap 和二维码安装策略，最后统一确认。此前取消或输入结束不会安装软件、分配编号或创建节点。
4. **集中执行**：按计划准备 Swap、依赖和二维码工具、Docker，再生成并校验节点配置、启动容器和自检。执行期间不再询问；可选二维码安装失败时跳过，核心准备失败时停止。
5. **展示结果**：分别显示状态、VMess 链接、二维码和 Nginx 提示，不再触发安装。已有 Nginx / 宝塔入口会提示等待手工配置，完成后通过「测试连接」验证。

全新服务器尚未安装 Python 时仍可先填写信息。高级设置显示预先生成的端口、路径和 UUID 默认值，回车即可采用；输入先做基础校验，工具就绪后再做完整校验，通过后才创建节点。

选择入口后，会只读检查该域名在本机 HTTPS 入口的证书是否通过信任和域名校验，并显示共享 Caddy 实际使用的 `/data` 存储，或预期证书卷的存在状态。数据卷存在不代表其中一定有可用证书；入口未启动或工具缺失时提示无法确认，不读取私钥，也不扫描或导入旧版证书。已有 Nginx / 宝塔的证书仍由原站点管理。

证书无法验证时，还会检查受管 Caddy 最近的该域名签发日志，提示限流及日志给出的重试时间。历史限流不代表当前仍受限，已有可信证书或后续签发成功时不会据旧错误报告当前限流。检查只提供信息，仍由最终确认决定是否执行；它不触发手工申请证书，也不关闭 TLS 校验。

「初始化环境」保留为独立入口，同样先检查和收集选择，汇总确认后集中执行，不创建节点。已有 Compose 版本过低或 Podman 冲突需自行处理，不自动替换已有组件。二维码可选，不安装也能使用客户端链接。

也可以下载脚本后使用子命令：

| 子命令 | 作用 |
| --- | --- |
| `init` | 初始化系统依赖和 Docker / Compose 环境 |
| `node-add` | 新增本机或中转节点 |
| `node-manage` | 选择节点，查看链接、修改、测试、查看日志、重启、删除或更新 |
| `nodes` | 查看节点配置与容器状态 |
| `node-update` | 选择并更新节点镜像 |
| `node-delete` | 选择并删除节点 |
| `ingress-update` | 更新共享 Caddy，失败时恢复原镜像 |

例如：

```bash
bash v2fly-auto-setup.sh init
bash v2fly-auto-setup.sh node-add
```

通过管道运行时，可以使用：

```bash
curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/main/v2fly-auto-setup.sh | sudo bash -s -- init
```

不要使用 `sudo bash <(curl ...)`：sudo 可能关闭进程替换所需的文件描述符，导致找不到脚本。使用上面的管道形式，或先切换到 root。

## 环境初始化

支持 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9、CentOS Stream 9；不支持 CentOS Linux、Stream 8 或 RHEL。初始化会检查系统、基础依赖和 Docker 服务。

- 已有 Docker 时保留引擎。缺少 Compose 时下载固定版本 v2.24.7 的官方插件，并校验 SHA-256；该插件不会由系统包管理器自动更新。
- EL9 新装 Docker 使用 Docker 官方 CentOS RPM 软件源。遇到 Podman 兼容命令或包冲突时停止，不自动卸载其他软件。
- 核验 `curl`、`openssl`、`python3`、`ss`、`ip` 和 `ca-certificates`。二维码工具 `qrencode` 可选；缺失时仍可输出客户端链接。二维码安装策略在执行前选择，默认选项 1：安装，EL9 必要时允许添加 EPEL 9；也可选择仅使用现有源或跳过安装。安装计划在最终确认后执行。
- 新增节点和环境初始化都会检查内存 / Swap，包括 Docker 和依赖已齐全的机器。内存不足 1 GiB 且无活动 Swap 时，在输入阶段询问是否计划创建 1 GiB Swap，默认不创建；拒绝则停止此次新增或初始化。实际创建仅在最终确认后执行。创建前检查 ext4 / XFS 和至少 2 GiB 可用磁盘，不覆盖已有 `/swapfile`，并备份 `/etc/fstab`。已有 Swap 保留。

Caddy 入口需要 TCP 80/443。脚本可处理活动的 ufw / firewalld；不会启动未运行的 firewalld。已有 Nginx 模式不修改防火墙。云厂商安全组需自行放行。

SELinux 保持开启；脚本不修改已有 Nginx 的全局 SELinux 策略。宝塔或站点管理员需确保 Nginx 可以连接节点回环端口。

## 宝塔面板 / 已有 Nginx

新增节点时选择「已有 Nginx」入口。脚本不会修改宝塔站点或证书配置。

1. 在宝塔为域名添加站点，申请并部署 SSL 证书。
2. 将脚本输出的 `location` 片段加入该站点监听 443 的 `server` 块。例如：

   ```nginx
   location = /example-path {
       proxy_pass http://127.0.0.1:2334;
       proxy_http_version 1.1;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header Host $host;
       proxy_read_timeout 300s;
   }
   ```

   路径和端口必须使用对应节点输出的值。每个节点添加自己的片段，不需要整站反向代理。
3. 检查并重载 Nginx，然后运行「管理节点 → 测试连接」。容器启动成功不代表 Nginx 转发已经配置完成。

复用同一个 Nginx 域名创建另一个节点后，仍需添加新路径。删除节点后，对应 Nginx 片段也需自行移除。

## 管理与失败恢复

「所有节点状态」显示节点容器、实际运行版本和镜像，并单独显示共享 Caddy 状态；按域名读取本机 HTTPS 入口的证书签发者与到期时间。证书尚未就绪时给出提示。

节点链接和二维码通过「管理节点 → 链接/二维码」查看。二维码按终端宽度选择纠错等级。查看链接时不安装工具；缺少 `qrencode` 会提示通过「初始化环境」补装。CentOS Stream 9 / Rocky 9 / AlmaLinux 9 按预先选择的策略使用现有源或官方 EPEL 9 源。跳过、安装失败或窗口过窄时仍保留导入链接。客户端参数为 VMess、WebSocket、TLS、端口 443、alterId 0，域名、UUID 和路径使用节点输出。

修改、重启、更新及删除只操作选中的节点容器。Caddy 是共享入口：入口路径发生变化时需要重载，现有 WebSocket 连接可能重连。

修改或更新前备份配置并记录原镜像 ID。应用或自检失败时尝试恢复原配置及原镜像，不依赖 `latest` 仍指向旧版本。恢复失败会保留备份并报告位置。临时连接测试只清理本次创建的容器；临时配置与备份按凭据保护。

共享 Caddy 通过主菜单「更新共享 Caddy」或 `ingress-update` 单独更新。更新前会提示所有 Caddy 节点可能短暂断连；更新失败时尝试恢复原镜像，恢复失败保留备份。已有 Nginx / 宝塔不由此操作更新。

「删除节点」选中并确认后，只删除目标节点的容器及配置，保留 Docker、依赖、其他节点和证书。最后一个 Caddy 节点删除后停止共享入口，证书卷仍保留。

连接测试包含 WebSocket 握手和临时 V2Fly 客户端的代理请求。服务器测试不能替代客户端实际网络验证；导入 Shadowrocket 后应通过代理查询出口 IP，确认直出和中转线路符合预期。

## Cloudflare CDN

节点使用域名、443 和 WebSocket + TLS。域名、路径和证书设置正确时，通常只需切换 Cloudflare DNS 的代理状态（橙云 / 灰云），无需修改节点配置。橙云经过 Cloudflare，灰云直连源站；仅把 DNS 托管到 Cloudflare 并不等于开启代理。参见 [Cloudflare DNS 代理说明](https://developers.cloudflare.com/dns/proxy-status/)。

使用代理时保持 WebSockets 开启，并为源站配置有效证书，SSL/TLS 使用“完全（严格）”。Cloudflare 的边缘证书也需覆盖节点域名。如果需要随时切回灰云，源站应使用客户端信任的证书（例如 Caddy 申请的公开 CA 证书）；只受 Cloudflare 信任的 [Origin CA 证书](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)不适合直接给客户端使用。参见 [WebSockets](https://developers.cloudflare.com/network/websockets/) 和 [完全（严格）模式](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)。

边缘检测属于诊断功能，不是启用 CDN 的前提。本脚本当前连接测试主要检查本机 HTTPS 入口及代理出口，不证明 Cloudflare 路径可用；启用代理后仍应在客户端测试。源站正常而客户端失败时，检查 Cloudflare 的证书、WAF 与 WebSocket 设置。

## 文件位置

```text
/root/v2fly-stack/nodes/.id-sequence        节点编号记录
/root/v2fly-stack/nodes/<id>/metadata.json  节点参数
/root/v2fly-stack/nodes/<id>/config.json    V2Fly 配置
/root/v2fly-stack/nodes/<id>/compose.yaml   节点独立容器定义
/root/v2fly-stack/ingress/Caddyfile         共享 Caddy 入口配置
/root/v2fly-stack/ingress/metadata.json     共享入口镜像记录（含回退镜像）
/root/v2fly-stack/ingress.yaml              共享入口容器定义
```

节点配置通过管理菜单修改。不要将真实 UUID、配置备份或证书提交到仓库。

## 本地验证

```bash
bash -n v2fly-auto-setup.sh
bash tests/regression.sh
bash tests/el9.sh
bash tests/swap.sh
bash tests/nodes.sh
bash tests/management.sh
bash tests/environment.sh
bash tests/qr-install.sh
bash tests/workflow.sh
```

测试需要 Bash 和 Python 3，使用临时目录和模拟命令，不下载依赖、不操作真实 Docker 或系统配置。模拟测试不能代替支持系统上的真实部署验证。
