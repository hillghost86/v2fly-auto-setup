# 项目约定

## 范围与结构

- 本项目是 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 和 CentOS Stream 9 上的 V2Fly + Caddy 安装管理脚本，支持已有 Nginx 的部署方式。
- `v2fly-auto-setup.sh` 是 Bash 入口；`README.md` 记录服务器使用方法。
- 运行配置位于服务器的 `/root/v2fly-stack`；新节点存放于 `nodes/<id>/`，每个节点独立 Compose 项目，Caddy 入口共享。不要把真实 UUID、域名配置或证书带入仓库。
- 本大版本固定使用 `/root/v2fly-stack`，不读取、接管或迁移旧单节点配置，不回退旧目录，也不自动清理旧资源。
- 多节点管理只处理本版本创建的节点；节点元数据按 JSON 解析，不作为 Shell 执行。单文件发布方式保持不变，Bash 负责交互与系统操作，内嵌 Python 负责数据校验、配置生成及链接处理。

## 开发与验证

- 在独立特性分支修改；默认远程分支为 `main`。
- 基础语法检查：`bash -n v2fly-auto-setup.sh`。
- 模拟回归检查：`bash tests/regression.sh`、`bash tests/el9.sh`、`bash tests/swap.sh`、`bash tests/nodes.sh`、`bash tests/management.sh`、`bash tests/environment.sh`、`bash tests/qr-install.sh` 和 `bash tests/workflow.sh`，无需 Docker 服务或额外测试框架。
- 本地验证使用模拟的 Docker、APT、DNF、防火墙和网络命令，不能直接运行脚本的安装、更新或卸载子命令。
- 模拟检查不能代替 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 和 CentOS Stream 9 上的真实部署验证，交付时明确未验证范围。
- 安装依赖、真实容器操作及服务器部署需另行获得用户授权。

## 恢复与资源归属

- 新增节点和独立初始化均按“只读检查与输入 → 汇总确认 → 集中执行 → 结果展示”组织。所有安装、Swap、EPEL 选择须在最终确认前完成，执行阶段不得再读取交互输入。取消或 EOF 不写节点、不安装。查看链接/二维码只展示，缺工具提示去初始化环境。低内存检查覆盖依赖已齐全的机器，保留原 Swap 安全保护和节点失败恢复。
- 入口证书预检只读：验证本机 HTTPS 的域名与信任链，展示当前证书存储；服务未运行不等于磁盘证书缺失。限流提示仅解析受管 Caddy 所选域名的近期日志，不输出原始日志或私钥，不导入旧证书，也不绕过 TLS 校验。
- 节点操作只重建目标 V2Fly 容器；共享入口更新必须检查资源归属，并明确连接重连影响。
- 清理只处理本次创建的资源；失败恢复使用变更前的配置和镜像，不依赖可变标签仍指向旧版本。
- 恢复失败时保留备份并明确报告；临时配置及备份中的 UUID 按凭据保护。
- 提交、推送、PR 和部署按用户授权分别执行。
