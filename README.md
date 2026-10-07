# v2fly-auto-setup.sh

一个脚本在 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 或 CentOS Stream 9 服务器上装好 **V2Fly v5 + Caddy 2**，用 **VMess + WebSocket + TLS** 组合，证书自动申请、自动续期。装完直接给出客户端链接和二维码。

全部跑在 Docker 里，不往系统里装 V2Ray 或 Nginx，卸载干净。

机器上已经有宝塔面板或别的 Nginx 占着 80 / 443 也能装：安装时选「已有 Nginx」模式，脚本只跑 V2Ray，证书和 443 交给 Nginx，见下方「[和宝塔面板共存](#和宝塔面板--已有-nginx-共存)」。

## 多节点与中转

同一台服务器可以运行多个独立 V2Fly 容器，每个节点有自己的 UUID、WebSocket 路径、回环地址端口和出站配置。HTTPS 入口可以共用域名和 443，通过不同路径分发；节点的修改、重启和删除按节点执行。

新增时先选择「本机节点」或「中转节点」，再填写节点名称（例如“日本2”），内部编号由脚本自动递增分配，无需另填标识或把域名当作标识。已删除节点的编号不会重新使用；已有英文标识的节点仍可通过管理列表选择。所有菜单选项逐行显示。

例如，在韩国服务器创建两个节点：

| 客户端节点 | 连接线路 | 网站看到的出口 |
| --- | --- | --- |
| 韩国直出 | Shadowrocket → 韩国 → 网站 | 韩国服务器 |
| 韩国转日本 | Shadowrocket → 韩国 → 日本 → 网站 | 日本服务器 |

分别导入两条 `vmess://` 链接，在 Shadowrocket 中切换即可。中转出口支持 VMess + WebSocket + TLS，可导入远端链接或手动填写地址、端口、UUID、WebSocket 路径及 TLS / Host 参数。中转失败不会自动切换为本机直出。

新增节点流程要求服务器已经准备好 Docker、满足版本要求的 Compose、Python 3 及脚本检查所需的基础工具；它不会自动安装系统依赖。创建或更新节点会按所选标签拉取容器镜像。

首次复用本脚本标准部署的旧 Caddy 入口时，需要重建一次 Caddy 以挂载持久化入口配置，现有连接会短暂中断；原单节点 `.env` 和 `compose.yaml` 保留。之后的路径变更使用重载。

入口菜单会列出脚本已登记的域名及其 HTTPS 管理方式，按序号即可复用，不需要再输入域名。没有登记入口时，直接选择新建 Caddy 入口或使用已有 Nginx / 宝塔；域名已解析并不等于已有可复用入口。新入口才需要填写域名，选错或输入无效序号可以重新选择，输入 `0` 返回。复用 Nginx 入口仍需将脚本输出的新路径反向代理片段加入对应 HTTPS 站点并重载；脚本不会修改面板配置，也不会替你操作云厂商安全组。Caddy 与已有 Nginx 不能同时争用同一地址的 80/443。

多节点管理只负责通过新流程创建的节点，不导入、识别或迁移手工修改的中转配置。旧版配置保留在原目录；需要两条可独立管理的线路时，分别新增直出节点和中转节点。

节点容器独立，HTTPS 前端仍为共享资源。新增、删除或修改入口路径需要更新前端配置；Caddy 重载可能使现有 WebSocket 连接重新建立，因此不能承诺入口变更完全无中断。仅修改节点出口或重启指定节点，不应重建其他节点容器。

## 需要准备

- 一台 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 或 CentOS Stream 9 服务器（需要 systemd，root 权限）
- 一个域名，A 记录指向服务器公网 IP
- 服务器防火墙放行 **TCP 80 和 443**（80 用来申请证书，不能省）

旧单节点 `install` 流程会安装 Docker、Docker Compose 和基础依赖。EL9 系列的二维码工具 `qrencode` 为可选依赖。当前软件源不提供时，脚本会询问是否添加 Fedora 官方 EPEL 9 软件源；同意后直接安装官方软件源 RPM，再安装工具。默认不添加；拒绝或安装失败时跳过二维码，客户端链接仍可正常输出。

基础依赖安装后会逐项核验 `curl`、`openssl`、`python3`、`ss`、`ip` 是否可用，以及 `ca-certificates` 是否已安装，并显示成功或缺失状态。核心依赖缺失会停止安装；`qrencode` 缺失会提示二维码不可用。Docker 另行检查服务响应和 Compose 版本。

已有 Docker 时不会替换 Docker 引擎。缺少 Compose 时，脚本会从 Docker 官方 GitHub 发布页下载固定版本 [v2.24.7](https://github.com/docker/compose/releases/tag/v2.24.7) 的独立插件，并校验 SHA-256；这种安装方式不会通过系统包管理器自动更新。新装 Docker 前会补齐 APT 软件源目录，兼容缺少该目录的精简系统。

安装依赖前会检查内存：物理内存不足 1 GiB 且没有正在使用的 Swap 时，脚本会询问是否创建 1 GiB Swap，默认不创建。拒绝时停止此次安装；同意后会检查文件系统为 ext4 / XFS、可用磁盘至少 2 GiB，创建权限为 600 的 `/swapfile`（不会覆盖已有文件），并备份 `/etc/fstab`、配置开机启用。已有 Swap 保留；不会调整 swappiness 或自动重启。Swap 可以缓解内存压力，但不能保证排除所有断连或重启原因。

EL9 首次安装 Docker 使用 Docker 官方 CentOS RPM 软件源；已有 Docker 时保留引擎。遇到 Podman 提供的兼容 `docker` 命令或软件包冲突会停止并给出提示，不自动卸载现有软件。

Caddy 模式会为公网出口网卡所在的活动 firewalld 区域开放 TCP 80/443，同时写入运行时和永久规则；不会启动未运行的 firewalld。已有 Nginx 模式不修改防火墙规则。SELinux 保持开启，连接测试的临时挂载使用独占标签。云厂商安全组仍需自行放行。已有 Nginx 的 SELinux 反向代理策略由站点管理员配置，脚本不会修改全局 SELinux 布尔开关。

CentOS Linux 8、CentOS Stream 8、RHEL 及其他发行版暂不在新增支持范围。

## 使用

所有子命令都要 root（配置在 `/root/v2ray-stack` 下，还要动 Docker、包管理器、systemd 和 80/443 端口）。先 `sudo -i` 切到 root，然后：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/main/v2fly-auto-setup.sh)
```

不想切 root 就用管道加 `sudo`：

```bash
curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/main/v2fly-auto-setup.sh | sudo bash -s -- install
```

> 唯独 `sudo bash <(curl ...)` **不能用**。进程替换的 `/dev/fd/63` 是调用者进程的管道，而 sudo 默认 `closefrom=3` 会关掉 3 号以上所有文件描述符，新进程再去打开它只会得到 `No such file or directory`。要么用上面的管道写法，要么下载到本地再 `sudo bash v2fly-auto-setup.sh`。

不带参数会进菜单：

```
 1) 新增节点
 2) 管理节点
 3) 所有节点状态
 4) 更新指定节点
 5) 删除节点
 6) 旧单节点菜单
 0) 退出
```

也可以直接指定子命令（把 `install` 换成下表里任意一个）：

| 子命令 | 作用 |
| --- | --- |
| `node-add` | 新增独立容器节点，选择 HTTPS 入口和直出 / 中转出口 |
| `node-manage` | 选择新节点，显示链接、修改、测试、查看日志、重启、删除或更新 |
| `nodes` | 列出节点配置和容器状态 |
| `install` | 旧单节点安装，或修改域名 / UUID / 路径后重新应用 |
| `update` | 更新旧单节点，失败时自动恢复旧配置和旧镜像 |
| `status` | 查看旧单节点的容器状态、版本、证书和链路 |
| `show` | 打印旧单节点的配置、链接和二维码（`show plain` 不画二维码） |
| `uninstall` | 卸载旧单节点，可选删除旧证书和配置目录 |

旧单节点 `install` 流程需要填 5 项，回车即用默认值：

- **域名** — 已解析到本机的那个
- **UUID** — 回车随机生成
- **WebSocket 路径** — 回车随机生成，例如 `/a1b2c3`
- **是否走 Cloudflare CDN** — 决定域名检查时的排查提示
- **HTTPS 由谁负责** — 默认脚本自带的 Caddy；机器上已有宝塔 / Nginx 占着 443 时选「已有 Nginx」（首次安装检测到 443 被占会自动把默认值切过去）

### 新增韩国直出和韩国转日本

使用本版本脚本，依次运行两次：

```bash
bash v2fly-auto-setup.sh node-add
```

第一次选择「本机节点」，填写节点名称并选择已有 Nginx 或 Caddy 入口。第二次选择「中转节点」，从列表按序号复用相同的入口域名，使用另一个自动生成的路径和本地端口，导入日本节点链接或手动填写远端参数。日本端继续使用原来的服务。

已有 Nginx 模式下，把两次输出的 `location` 配置分别加入域名的 HTTPS `server` 块，检查 Nginx 配置并重载后，通过「管理节点 → 测试连接」验证。Nginx 尚未配置时，容器启动不等于客户端已经可以连接。

主菜单「删除节点」会直接列出节点，选中后确认删除；不必再进入管理操作菜单。它只删除所选节点的容器和配置，保留 Docker、系统依赖、证书及其他节点。最后一个独立 Caddy 节点删除后会停止对应的共享入口，证书卷仍保留；已有 Nginx 的对应反向代理片段需手动移除。管理菜单内的「删除」执行相同操作。

分别复制输出的节点链接导入 Shadowrocket。切换到对应节点，通过代理查询出口 IP，确认直出节点为韩国出口、中转节点为日本出口。规则模式下被配置为直连的请求不会走这些节点。

## 装完之后

脚本会直接输出可粘贴的 `vmess://` 链接（v2rayN、Shadowrocket 等通用），以及扫码用的二维码。二维码的宽度取决于链接长度，脚本会按实际尺寸和终端宽度挑纠错等级（优先 M，装不下退 L），实在放不下就跳过并告诉你还差几列。手动填的话：

| 项 | 值 |
| --- | --- |
| 地址 / Host / SNI | 你的域名 |
| 端口 | 443 |
| UUID | 安装时生成的那个 |
| Alter Id | 0 |
| 加密 | auto |
| 传输 | websocket |
| 路径 | 安装时生成的那个 |
| TLS | 开启 |

忘了就跑一次脚本选「显示客户端链接」。

### 用 Cloudflare CDN 的话

安装时把 CDN 选 `yes`，并在 Cloudflare 侧：

- 域名必须是**一级子域**，例如 `aws.example.com`。见下方说明
- 云朵改成**橙色**（已代理）
- SSL/TLS 模式选**完全（严格）**
- 网络里 **WebSockets 保持开启**
- **不要**开启「始终使用 HTTPS」（会挡住证书申请）

> **多级子域用不了。** Cloudflare 免费版 Universal SSL 只签 `example.com` 和 `*.example.com`，通配符不覆盖 `aws.no2.example.com` 这种多级子域。橙色云朵下客户端连的是 Cloudflare 边缘，边缘拿不出证书，直接回一个握手失败。
>
> 迷惑之处在于**源站一切正常**：Let's Encrypt 不限子域层级，证书照发，服务器上怎么测都是绿的，偏偏客户端连不上。判断方法：
>
> ```bash
> echo | openssl s_client -connect 你的域名:443 -servername 你的域名 2>&1 | head -5
> ```
>
> 出现 `no peer certificate available` 就是这个问题。解决办法：换一级子域（推荐）、把云朵改灰（同时把脚本的 CDN 选项改成 `no`），或购买 Advanced Certificate Manager 开启 Total TLS。

## 和宝塔面板 / 已有 Nginx 共存

Caddy 模式要独占 80 和 443，机器上装了宝塔面板（或任何 Nginx / Apache）就会撞端口。给 Caddy 换端口也绕不开：证书验证只认 80 和 443，而 Nginx 在前面七层反代的话自己就得有证书，Caddy 那张就白申请了。所以脚本干脆提供了另一种分工：

| | Caddy 模式（默认） | 已有 Nginx 模式 |
| --- | --- | --- |
| 跑的容器 | v2ray + caddy | 只有 v2ray |
| V2Ray 端口 | 仅容器内网 | `127.0.0.1:2333`，外网碰不到 |
| 证书申请 / 续期 | Caddy 自动 | 宝塔面板 |
| 443 上的反代 | Caddy | 你在站点配置里加一段 `location` |
| 客户端配置 | 域名、443、TLS、路径 | 完全一样 |

安装时「HTTPS 由谁负责」选 2，脚本启动 V2Ray 后会打印出要贴进宝塔的配置，照做即可：

1. 宝塔里给这个域名**添加站点**（纯静态就行），**申请 SSL 证书**并部署。
2. 打开站点的**配置文件**，在 443 的 `server` 块里加入（路径换成安装时生成的那个）：

   ```nginx
   location /a1b2c3 {
       proxy_pass http://127.0.0.1:2333;
       proxy_http_version 1.1;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_read_timeout 300s;
   }
   ```

   不要用面板的「反向代理」功能整站反代，那会把根路径也转给 V2Ray。只加这一个 `location`，域名根路径照常显示站点内容，比 Caddy 那句 "It works!" 更不显眼。
3. 保存重载后回到脚本按回车，自检会分两段：先直连 2333 确认 V2Ray 本身是好的，再经 443 走一遍 Nginx 确认证书和反代。哪段没过就知道该查哪边。

这个模式下脚本**不做 80 端口的域名检查**（端口在 Nginx 手里，起不了临时服务），DNS 是否正确靠宝塔申请证书那一步验证。证书续期也归宝塔，`status` 里的证书有效期读的是 443 上宝塔部署的那张。

已经装成 Caddy 模式的机器，重跑安装选 2 即可切换：`--remove-orphans` 会删掉 caddy 容器，证书卷保留。反过来从 Nginx 模式切回 Caddy，得先把 Nginx 从 80 / 443 上挪开。

## 脚本做了哪些检查

这是它跟大多数一键脚本不一样的地方——不是启动完就宣布成功。

1. **装之前查域名**：临时在 80 端口起一个网页服务，再从外网经域名访问它。一次性验证 DNS 解析、云厂商防火墙、CDN 转发三件事，比 `ping` 靠谱。顺带检查 AAAA 记录是否指向别处。
2. **装之后查握手**：模拟一次 WebSocket 升级请求，返回 101 才算 Caddy → V2Ray 链路通、证书有效。
3. **最后查真连通**：起一个临时 V2Ray 客户端容器，用刚生成的 UUID 真的走一遍代理去访问外网。这一步过了，说明 UUID、路径、TLS 全都对，而不只是端口开着。
4. **CDN 模式下还要查边缘**：上面几项为了排除干扰都绕开了 Cloudflare，所以照不出边缘的毛病。开了 CDN 时会按域名真实解析再做一次 WebSocket 握手，也就是客户端实际走的那条路。不过就打印 curl 的原话和 HTTP 状态码，并按状态码给出方向：连不上或 TLS 失败、没被当作 WebSocket 升级（多半是 Cloudflare 的 WebSockets 开关）、被 WAF 拦下、Cloudflare 连不上源站（52x）等。

任何一步没过都会打印对应容器的日志和排查方向。连接测试使用本次运行创建的临时容器，只按其 ID 清理；临时配置中的 UUID 仅 root 可读，退出时清理。

修改已有安装或运行 `update` 时，会先备份配置并记录旧镜像。拉取失败会恢复配置；重建或自检失败会尝试恢复原配置和原镜像，而不是重新下载可能已变化的 `latest`。恢复失败时保留备份目录并打印位置，命令以失败状态退出。首次安装没有旧版本可恢复，失败时保留配置供排查。

需要恢复容器时，镜像标签会停在 `rollback`：这时重跑「安装 / 修改配置」不会去拉镜像，继续用回退的版本；下次「更新」则会再次尝试最新版。更新成功后也保留旧镜像，不自动清理。

## 文件位置

```
/root/v2ray-stack/.env           域名、UUID、路径、前端模式、镜像版本（权限 600）
/root/v2ray-stack/compose.yaml   容器定义，V2Ray 和 Caddy 的配置内嵌其中
/root/v2ray-stack/nodes/.id-sequence        节点编号分配记录（删除节点不回退）
/root/v2ray-stack/nodes/<id>/metadata.json  新节点参数（权限 600）
/root/v2ray-stack/nodes/<id>/config.json    新节点 V2Fly 配置（权限 600）
/root/v2ray-stack/nodes/<id>/compose.yaml   每个节点的独立容器定义
/root/v2ray-stack/ingress/Caddyfile         共享 Caddy 入口配置
/root/v2ray-stack/ingress.yaml              共享入口定义或标准旧 Caddy 的覆盖文件
docker volume caddy_data         HTTPS 证书（仅 Caddy 模式）
docker volume caddy_config       Caddy 运行时配置（仅 Caddy 模式）
```

新节点请通过「管理节点 → 修改」更新配置。旧单节点仍通过旧菜单修改；存在新节点或共享入口覆盖文件时，旧安装、更新和卸载操作会被阻止，避免覆盖共享入口或删除新节点目录。

## 常见问题

**证书申请不下来** — 九成是 80 端口没通。检查云厂商防火墙（Lightsail 之类的安全组和系统 ufw 是两回事，脚本只会帮你开 ufw）、A 记录是否生效、Cloudflare 是否开了「始终使用 HTTPS」。

**80 端口被占用导致检查中止** — 先查是谁占着：

```bash
ss -tlnp | grep ':80 '
```

占着的是宝塔 / Nginx 的话不用停它，重跑安装把「HTTPS 由谁负责」选成「已有 Nginx」，见上面「和宝塔面板共存」。

**Nginx 模式下「经 443 握手失败」但「V2Ray 正常」** — 问题在 Nginx 这一跳：站点证书没申请或没部署、`location` 没加进 443 的 `server` 块、没重载，或者少了 `Upgrade` / `Connection` 头（那样会返回 200 或 400 而不是 101）。改完 `nginx -t && nginx -s reload`，再跑「查看运行状态」。

**服务起来了但连不上** — 跑一次「查看运行状态」，三项自检会分别指出是证书/握手、UUID/路径，还是 Cloudflare 边缘的问题。特别注意「源站全绿但客户端连不上」这种情况，多半是上面说的多级子域。

**提示需要 root** — 所有子命令都要 root，包括只读的 `status` 和 `show`（配置在 `/root/v2ray-stack` 下，`.env` 是 600）。用法见上面「使用」一节。

**在 Windows 上编辑过脚本** — 脚本开头自带 CRLF 自愈，是磁盘上的普通文件时会去掉 `\r` 再重新执行自己，不用手动 `dos2unix`。通过管道运行时不做这个检查（那种情况下也不会有 CRLF），否则读取自身会把数据从管道里抢走、导致脚本被截断。

**看日志**：

```bash
docker logs --tail 50 caddy
```

```bash
docker logs --tail 50 v2ray
```

## 本地验证

```bash
bash -n v2fly-auto-setup.sh
bash tests/regression.sh
bash tests/el9.sh
bash tests/swap.sh
bash tests/nodes.sh
```

回归测试需要 Bash 和 Python 3，使用模拟命令检查安装分支、资源清理和失败恢复，不下载依赖、不操作真实 Docker 或系统配置。它不能代替服务器上的实际部署验证。

## 说明

仅供在你自己拥有或获得授权的服务器上搭建个人代理使用，请遵守所在地法律法规。
