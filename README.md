# DevEnvUbuntu

一键安装 Ubuntu 22.04+（含 Windows 11 WSL2）开发环境：

- **JDK 8（默认）+ JDK 17**（SDKMAN 管理，`sdk use java 17.x.x-tem` 切换）
- **Node.js 20 LTS**（nvm）
- **Python 3.12**（pyenv）
- **Git**、**Maven 3.9.x**
- **Claude Code CLI** + **clautel**（npm 全局）
- WSL2 下"始终在线"四件套：Windows 开机自启 WSL、不空闲超时、clautel 崩溃自拉起、网络保活记录

> **默认走官方上游**（api.sdkman.io / nodejs.org / pypi.org / Maven Central / GitHub）。
> 国内不能科学上网的用户加 `--mirror` 启用 USTC / bfsu / npmmirror / 清华 / 阿里云 / gitee 加速。

## 一键安装（Linux/WSL 端）

```bash
git clone https://github.com/<you>/DevEnvUbuntu.git
cd DevEnvUbuntu
bash install.sh
```

可选参数：

| 参数 | 说明 |
|---|---|
| `--mirror` | 启用国内镜像（默认关）：apt/SDKMAN/npm/pip/Maven/nvm/pyenv 全套加速 |
| `--no-mirror` | 显式禁用镜像（同默认；并清理之前残留的镜像配置） |
| `--status` | 只打印当前各工具状态表，不执行安装 |
| `-y`, `--yes` | 跳过开始前的 [Y/n] 确认 |
| `--skip-keepalive` | 跳过 systemd user services 部署（CI 场景） |
| `--only NAME` | 只跑指定模块；可多次传 |
| `--skip NAME` | 跳过指定模块；可多次传 |
| `--git-user NAME` `--git-email ADDR` | 写入 git 全局 user.name/email |

完成后请运行 `claude login` 完成 Claude 认证。

## Windows 端（仅 WSL2 用户）

完成 Linux 端安装后：

1. 在文件资源管理器中找到 `windows\run-as-admin.bat`，**双击**
2. UAC 弹窗 → 同意（脚本会自动以管理员重启）
3. 看到 "=== 完成 ===" 即成功

这一步会：

- 写入 `%USERPROFILE%\.wslconfig`（防止 WSL 空闲超时关闭）
- 注册 Windows 任务计划 `DevEnvUbuntu-WSL-Keepalive`，登录时跑 `wsl ... sleep infinity` 维持 WSL 在线

## 验证

```bash
bash modules/99-verify.sh
# 或扩展冒烟测试
bash tests/smoke.sh
```

## WSL 启用 systemd

`12-keepalive` 模块需要 systemd。如果你的 WSL 还没启用：

1. 编辑 `/etc/wsl.conf`，加入：

   ```ini
   [boot]
   systemd=true
   ```

2. 在 PowerShell 跑 `wsl --shutdown`
3. 重新打开 WSL 终端，再跑 `bash install.sh --only 12-keepalive`

（`12-keepalive` 模块会自动写入这段配置，但需要你手动 `wsl --shutdown` 一次。）

## 卸载/清理

- SDKMAN：`rm -rf ~/.sdkman` 并清掉 `~/.bashrc` 中 `# >>> DevEnvUbuntu SDKMAN >>>` 块
- nvm / pyenv 同理：`rm -rf ~/.nvm ~/.pyenv` + 清块
- npm 全局：`npm uninstall -g @anthropic-ai/claude-code clautel`
- systemd 服务：`systemctl --user disable --now clautel.service net-keepalive.timer && rm ~/.config/systemd/user/{clautel,net-keepalive}.{service,timer}`
- Windows 任务：`Unregister-ScheduledTask -TaskName DevEnvUbuntu-WSL-Keepalive -Confirm:$false`

## 常见问题

**Q：第二次跑 install.sh 会重复装吗？**
A：不会。每个模块开头都有"已就绪"判断，重跑只会快速核对。

**Q：在公司内网无法访问 github 怎么办？**
A：默认就走国内镜像（USTC/bfsu/gitee/npmmirror/清华/阿里云）。如果连 gitee 也不通，可设置 HTTP 代理：`https_proxy=http://your-proxy ALL_PROXY=http://your-proxy bash install.sh`。

**Q：clautel 启动时怎么传配置/key？**
A：本项目只负责把 `clautel` 装到 PATH。具体启动参数/认证方式见 clautel 自身文档；如果它需要环境变量，在 `~/.config/systemd/user/clautel.service.d/env.conf`（drop-in 目录）中追加 `Environment=KEY=VALUE`。

## 详细设计

[docs/superpowers/specs/2026-05-10-dev-env-installer-design.md](docs/superpowers/specs/2026-05-10-dev-env-installer-design.md)
