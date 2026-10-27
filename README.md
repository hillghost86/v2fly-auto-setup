# V2Fly Auto Setup

**在一台服务器上创建多个代理节点，按需选择本机直出或远端中转。**

通过 Docker 部署 V2Fly v5，使用 **VMess + WebSocket + TLS**。每个节点独立运行，共用 HTTPS 入口；支持 Caddy 自动管理证书，也支持接入已有 Nginx / 宝塔站点。

[发布版本 0.3.2](https://github.com/hillghost86/v2fly-auto-setup/releases/tag/0.3.2) · [快速开始](#快速开始) · [宝塔接入](#宝塔--已有-nginx) · [常见问题](#常见问题)

> **从旧版本升级？先看这里。**
>
> `0.3.2` 可以继续管理 `0.3.0`、`0.3.1` 创建的节点。新增节点时默认计划启用 BBR + fq，也可通过菜单 8 单独启用；已有受管优化配置直接沿用。
>
> `0.3.0` 不支持直接管理 `0.2.0` 或旧单节点版本创建的资源。请先备份节点信息和证书，用旧版管理方式清理旧部署，再重新创建节点。
>
> 两版都使用 `/root/v2fly-stack`，仅替换脚本并不等于完成升级。新版不会自动迁移旧容器或证书卷，也不会自动删除旧资源。重新申请证书可能遇到签发限流。

## 能做什么

例如，在韩国服务器创建两个节点：

| 客户端里选择 | 数据经过的线路 | 网站看到的出口 |
| --- | --- | --- |
| 韩国直出 | 你的设备 → 韩国 → 网站 | 韩国服务器 |
| 韩国转日本 | 你的设备 → 韩国 → 日本 → 网站 | 日本服务器 |

把两条链接分别导入 Shadowrocket 等客户端，需要哪条线路就切换到哪个节点。**中转失败时，不会自动改为本机直出。** 客户端规则中设为直连的请求仍然直接连接，不经过节点。

- **多个节点独立管理**：每个节点有自己的名称、UUID、路径、本地端口和容器。
- **同域名复用**：不同节点可以共用域名和 443 端口，通过不同 WebSocket 路径转发。
- **远端链接导入**：创建中转节点时，粘贴远端 `vmess://` 链接即可解析并核对连接参数。
- **先填写，再执行**：安装依赖、创建 Swap 和部署容器，都在最终确认后进行。

## 快速开始

### 1. 准备服务器与域名

| 项目 | 要求 |
| --- | --- |
| 系统 | Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9、CentOS Stream 9 |
| 权限 | root；系统使用 systemd |
| 域名 | 已解析到这台服务器 |
| 网络 | 放行入口所需的 TCP 80、443，包括云厂商安全组 |
| 中转节点 | 另有一个可用的 VMess + WebSocket + TLS 远端节点 |

不支持 CentOS Linux、CentOS Stream 8 或 RHEL。已有 Docker 可以继续使用；其他缺失的依赖会在确认后准备。

### 2. 选择入口方式

| 服务器情况 | 应该选什么 | 证书由谁管理 |
| --- | --- | --- |
| 没有网站服务，80/443 空闲 | Caddy 新域名 | Caddy 自动申请和续期 |
| 已有 Nginx 或宝塔网站 | 已有 Nginx 新域名 | 原站点管理 |
| 已用本脚本创建过同域名节点 | 复用列表中的域名 | 沿用原入口 |

同一台服务器上的脚本节点须使用同一种入口方式，避免 Caddy 与 Nginx 争用端口。**域名已经解析，不等于已有可复用入口**；菜单只列出脚本登记过的入口。

### 3. 运行脚本

先使用 `sudo -i` 切换到 root；已经是 root 则无需执行。

推荐使用固定版本，方便复现配置和排查问题：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/0.3.2/v2fly-auto-setup.sh)
```

<details>
<summary>使用 main 最新代码，或下载到本地运行</summary>

`main` 可能包含尚未发布的新改动：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/main/v2fly-auto-setup.sh)
```

下载固定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/0.3.2/v2fly-auto-setup.sh -o v2fly-auto-setup.sh
bash v2fly-auto-setup.sh
```

不要使用 `sudo bash <(curl ...)`，它可能无法读取进程替换生成的脚本。先切换到 root，或使用管道形式：

```bash
curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/0.3.2/v2fly-auto-setup.sh | sudo bash -s -- init
```

上面的管道命令只初始化环境，不创建节点。若运行命令本身提示找不到 `curl`，需先通过系统包管理器安装它。

</details>

### 4. 创建第一个节点

进入主菜单后，直接选择 **「1) 新增节点」**，不用先初始化环境。

1. 选择「本机节点」或「中转节点」，输入方便识别的名称。
2. 选择入口，填写域名。端口、UUID 和路径通常采用默认值即可。
3. 如果是中转节点，导入远端 VMess 链接，或手动填写参数；核对解析出的地址、端口、路径、Host 和 SNI。
4. 选择环境准备项目，检查最终汇总，再确认执行。
5. 等待部署结束，复制 VMess 链接或扫描二维码导入客户端。

输入框中的 `[内容]` 是默认值，直接回车即可使用；带有「0 返回」的选项可以取消。最终确认前不会安装软件或创建节点。

新增节点时，会在环境准备阶段询问是否启用 BBR + fq，默认开启；已通过脚本启用过的服务器直接沿用，不再询问或重复设置。选择开启后，相关依赖安装和网络配置都在最终总确认后执行。编辑已有节点不会增加这个询问；若网络优化成功后节点创建失败，优化配置会保留，脚本会明确提示。

首次安装没有 Python 时，仍可先填写信息；远端链接会提示暂时无法解析，环境准备完成后再校验并展示。

**选择已有 Nginx / 宝塔时，还需完成下面的转发配置，节点才能从外部连接。**

### 5. 再加一个中转节点

在同一台服务器再次选择「新增节点 → 中转节点」，入口选择已有域名，再导入远端链接即可。

| 设置 | 第一个节点 | 第二个节点 |
| --- | --- | --- |
| 域名、HTTPS 端口 | 同一域名，443 | 复用同一入口 |
| 本地端口 | 例如 2333 | 例如 2334 |
| WebSocket 路径 | 例如 `/one` | 例如 `/two` |
| 出口 | 本机直出 | 远端中转 |

本地端口和同域名下的路径不能重复。默认端口会避开已登记或检测到占用的端口；执行前也会再次检查。

## 宝塔 / 已有 Nginx

脚本不会修改你的站点或证书配置。按以下步骤接入：

1. 在宝塔或 Nginx 中为域名配置 HTTPS 站点和有效证书。
2. 新增节点时选择「已有 Nginx」入口。
3. 把脚本输出的转发片段加入该站点监听 443 的 `server` 块。
4. 检查并重载 Nginx，再运行「管理节点 → 测试连接」。

片段示例，**路径和端口要使用脚本实际输出的值**：

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

每个节点添加自己的路径片段，不需要把整站都反向代理到节点。复用域名新增节点时仍需添加新路径；删除节点后，对应片段也需自行移除。

节点本地端口只监听 `127.0.0.1`，无需向公网开放。启用 SELinux 的机器还需确保 Nginx 有权限连接该端口；脚本不会关闭 SELinux 或修改已有 Nginx 的全局策略。

## 日常管理

再次运行脚本即可打开菜单：

| 菜单 | 用途 |
| --- | --- |
| 1) 新增节点 | 创建直出或中转节点 |
| 2) 管理节点 | 查看链接/二维码、修改、测试连接、查看日志、重启、删除或更新 |
| 3) 所有节点状态 | 查看容器、实际镜像、程序版本和证书信息 |
| 4) 更新指定节点 | 更新选中节点的 V2Fly 镜像 |
| 5) 删除节点 | 选择一个节点并确认删除 |
| 6) 初始化环境 | 单独准备依赖、Docker 或二维码工具，不创建节点 |
| 7) 更新共享 Caddy | 更新所有 Caddy 节点共用的 HTTPS 入口 |
| 8) 启用 BBR + fq | 检查并配置宿主机与本项目容器的网络优化 |
| 9) 网络优化状态 | 查看宿主机、节点容器的拥塞算法和出口网卡队列 |
| 0) 退出 | 结束本次操作 |

删除节点会保留 Docker、系统依赖、其他节点和证书卷。删除最后一个 Caddy 节点时，会停止共享入口，但仍保留证书卷。

修改或更新失败时，脚本会尝试恢复变更前的配置和镜像；如果恢复失败，会提示备份位置。共享 Caddy 更新或配置重载可能导致已有连接重连。

启用 BBR + fq 前会展示影响并要求确认：宿主机默认算法改为 BBR，出口网卡使用 fq，本项目现有节点和共享 Caddy 会重建，新节点继承配置。fq 会影响该网卡上的其他流量；实际速度提升取决于线路。操作前会检查默认路由、队列及现有设置，不支持的队列、冲突的配置或未运行的节点需要先人工处理。如果之前手工添加过 `compose.override.yaml`，需要先处理该文件，脚本不会自动覆盖。启用后可通过「网络优化状态」检查实际结果；删除节点不会自动撤销宿主机设置。请保管脚本提示的备份目录，其中可能包含节点凭据。

fq 通过 `net.core.default_qdisc=fq` 持久化，首次启用会立即切换出口队列，无需重启服务器；多队列网卡保留 mq，子队列使用 fq。以后启动时由系统默认设置创建队列，不安装额外的 fq 开机服务；其他网络管理程序若覆盖队列，需通过状态菜单检查实际结果。

**容器显示 running 只代表进程在运行。** 请再执行节点连接测试，并在客户端切换节点、查询出口 IP，确认实际线路符合预期。

## 常见问题

### 必须先安装 Docker 或初始化环境吗？

不必。直接新增节点即可，脚本先检查环境，在最终确认后准备缺失项目。已有 Compose 版本过低或 Podman 冲突时会提示自行处理，不自动替换这些组件。

### 为什么提示创建 Swap？

Swap 是磁盘上的交换空间，用来缓解内存不足。物理内存不足 1 GiB 且没有活动 Swap 时，脚本会询问是否创建 1 GiB Swap；拒绝则停止本次新增或初始化。已有 Swap 会保留。

### 选了安装二维码，为什么先出现找不到 qrencode？

在 CentOS Stream 9、Rocky 9、AlmaLinux 9 上，脚本先尝试现有软件源。选择策略 1 后，如果现有源找不到，会按需添加 EPEL 9（额外的软件仓库）再试。请看安装结束后的最终提示，不要只看第一次尝试的结果。

二维码是可选功能。安装失败、选择不安装或终端太窄时，都可以复制 VMess 链接导入。以后可通过「初始化环境」补装；查看链接时不会临时安装工具。

### 证书预检说无法确认，是证书丢了吗？

不一定。入口未启动、连接超时或工具缺失，都可能导致无法验证。预检会显示本机 HTTPS 验证结果和 Caddy 当前证书存储；数据卷存在也不代表里面一定有该域名的可用证书。

### 证书申请遇到 rateLimited / HTTP 429 怎么办？

先看提示中的允许重试时间，保留证书数据，不要反复删除证书卷重装。脚本会从受管 Caddy 的近期日志中查找所选域名的限流记录，并区分历史记录与尚未到达的重试时间。最终能否签发仍以证书服务的最新响应为准。

### 服务器测试通过，客户端还是连不上？

脚本主要检查本机 HTTPS 入口和代理出口。客户端到服务器之间的网络、云安全组，以及经过 CDN 的链路，还需要在客户端实际验证。

## 使用 Cloudflare CDN

域名、路径和证书配置正确时，通常只需切换 DNS 记录的代理状态，无需修改节点配置：

| 状态 | 连接方式 |
| --- | --- |
| 灰云（仅 DNS） | 客户端直接连接服务器 |
| 橙云（已代理） | 客户端通过 Cloudflare 连接服务器 |

使用橙云时，保持 WebSockets 开启，SSL/TLS 模式选择「完全（严格）」，并确保 Cloudflare 和服务器两端的证书都覆盖节点域名。如果还需要切回灰云，服务器应使用客户端信任的证书；Cloudflare Origin CA 证书不适合客户端直接连接。

开启 CDN 后，请在客户端重新测试。服务器本机测试通过，不代表 CDN 路径也正常。

官方说明：[DNS 代理状态](https://developers.cloudflare.com/dns/proxy-status/) · [WebSockets](https://developers.cloudflare.com/network/websockets/) · [完全（严格）](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/) · [Origin CA](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)

## 高级说明

<details>
<summary>环境安装与系统设置</summary>

- 核心依赖包括 curl、OpenSSL、Python 3、ss、ip 和系统 CA 证书。
- 已有 Docker 引擎会保留。缺少 Compose 时，下载固定版本 v2.24.7 的官方插件并校验 SHA-256；该插件不会由系统包管理器自动更新。
- EL9 新装 Docker 使用 Docker 官方 CentOS RPM 软件源；遇到 Podman 冲突时停止，不自动卸载其他软件。
- 二维码默认策略为 1：安装，EL9 必要时允许添加 EPEL 9。也可选择仅现有源或不安装。
- 创建 Swap 前会检查 ext4 / XFS 文件系统及至少 2 GiB 可用磁盘，不覆盖已有 `/swapfile`，并备份 `/etc/fstab`。
- Caddy 模式可为已启用的 ufw / firewalld 放行 TCP 80/443，不会启动未运行的 firewalld；Nginx 模式不修改防火墙。云安全组需自行设置。

</details>

<details>
<summary>命令行子命令</summary>

下载脚本后，使用 `bash v2fly-auto-setup.sh <子命令>`：

| 子命令 | 用途 |
| --- | --- |
| `init` | 初始化环境 |
| `node-add` | 新增节点 |
| `node-manage` | 管理节点 |
| `nodes` | 查看状态 |
| `node-update` | 更新节点镜像 |
| `node-delete` | 删除节点 |
| `ingress-update` | 更新共享 Caddy |

这些命令仍按需交互，不是无人值守部署接口。

</details>

<details>
<summary>配置文件与 Docker 资源位置</summary>

部署目录固定为 `/root/v2fly-stack`：

```text
/root/v2fly-stack/
├── nodes/
│   ├── .id-sequence          # 节点编号记录，删除节点后不复用编号
│   └── <编号>/
│       ├── metadata.json    # 节点信息
│       ├── config.json      # V2Fly 配置
│       └── compose.yaml     # 节点容器定义
├── ingress/
│   ├── Caddyfile             # 共享入口配置
│   └── metadata.json        # 共享入口镜像记录
└── ingress.yaml             # 共享入口容器定义
```

| 资源 | 名称 |
| --- | --- |
| 节点容器 / Compose 项目 | `v2fly-node-<编号>` |
| 节点 Compose 服务 | `v2fly` |
| 容器内配置文件 | `/etc/v2fly/config.json` |
| 共享 Caddy 容器 / 项目 | `v2fly-ingress` |
| 共享入口网络 | `v2fly-ingress_default` |
| Caddy 证书数据卷 | `v2fly-ingress_node_caddy_data` |

优先通过管理菜单修改节点。UUID 和 VMess 链接包含连接凭据，请勿公开，也不要将真实配置、备份或证书提交到仓库。

</details>

<details>
<summary>开发与本地验证</summary>

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
bash tests/network-bbr.sh
```

测试需要 Bash 和 Python 3，使用临时目录和模拟命令，不下载依赖、不操作真实 Docker 或系统配置。模拟测试不能代替各支持系统上的真实部署验证。

</details>
