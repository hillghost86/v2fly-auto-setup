# 项目约定

## 范围与结构

- 本项目是 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 和 CentOS Stream 9 上的 V2Fly + Caddy 安装管理脚本，支持已有 Nginx 的部署方式。
- `v2fly-auto-setup.sh` 是 Bash 入口；`README.md` 记录服务器使用方法。
- 运行配置位于服务器的 `/root/v2ray-stack`；不要把真实 UUID、域名配置或证书带入仓库。

## 开发与验证

- 在独立特性分支修改；默认远程分支为 `main`。
- 基础语法检查：`bash -n v2fly-auto-setup.sh`。
- 模拟回归检查：`bash tests/regression.sh` 、`bash tests/el9.sh` 和 `bash tests/swap.sh`，无需 Docker 服务或额外测试框架。
- 本地验证使用模拟的 Docker、APT、DNF、防火墙和网络命令，不能直接运行脚本的安装、更新或卸载子命令。
- 模拟检查不能代替 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 和 CentOS Stream 9 上的真实部署验证，交付时明确未验证范围。
- 安装依赖、真实容器操作及服务器部署需另行获得用户授权。

## 恢复与资源归属

- 修改安装流程时覆盖已有 Docker、缺少 Compose、首次安装及修改现有配置的场景。
- 清理只处理本次创建的资源；失败恢复使用变更前的配置和镜像，不依赖可变标签仍指向旧版本。
- 恢复失败时保留备份并明确报告；临时配置及备份中的 UUID 按凭据保护。
- 提交、推送、PR 和部署按用户授权分别执行。
