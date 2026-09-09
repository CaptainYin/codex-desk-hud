# Codex Desk HUD

[English](README.md) | **简体中文**

把 **Windows 上的 Codex 和 WSL Docker 容器里的 Codex** 放进同一个桌面置顶小窗。看剩余额度、看最近任务状态，少切几次终端和应用。

![Codex Desk HUD 悬浮窗，使用虚构演示数据](docs/hud-demo.png)

*配图由真实 WPF 界面渲染，任务名称、额度均为虚构演示数据，不含个人会话。当前应用界面为中文，README 提供中英文切换。*

## 和已有工具有什么不同？

本项目面向一个具体组合：**Windows 本地 Codex + 通过 WSL 访问的 Docker 容器 Codex，同时展示**。Windows 端使用 PowerShell/WPF，容器探针支持 Node.js 或 Python，无需构建前端。

| 项目 | 文档中的主要定位 | 本项目的侧重点 |
| --- | --- | --- |
| [Codex Monitor HUD](https://github.com/LH-03/codex-monitor-hud) | Windows Desktop、VS Code、CLI 的任务悬浮窗，提供更丰富的显示模式 | 用较小的脚本实现，提供明确的 WSL → Docker 数据采集路径。 |
| [codex-monitor-windows](https://github.com/itsnitinr/codex-monitor-windows) | 账号额度与账号切换，支持 Windows 或 WSL 目标 | 把最近会话状态和额度放在一起，同时展示 Windows 与 Docker 来源；不管理账号切换。 |

对比依据为 2026-09-09 查阅的上述项目 README，体现定位差异，不声称其他项目无法实现，也不宣称本项目是首创。

## 能做什么

- 桌面置顶、拖动、透明度设置、托盘隐藏/显示。
- 展示 Windows Codex App/CLI 与可选 WSL Docker 容器中的最近会话。
- 根据本地日志事件推断运行中、已结束、已中止、疑似中断或未知状态。
- 通过 `codex app-server` 读取剩余额度与重置时间；只展示接口实际返回的额度窗口。
- 实时查询失败时尝试日志缓存，并标注“非实时”。
- 隐藏启动器、可选桌面/开机快捷方式、本地诊断日志。
- 限制 Windows 日志尾部读取量，并持续读取额度进程的错误输出，修复此前启动卡住的问题。

## 开始使用

需要 Windows、Windows PowerShell 5.1 和 WPF。实时额度需要已安装并登录的 Codex。Docker 功能还需要 WSL、运行中的容器、容器里的 Codex，以及 **Node.js 或 Python 3**。

1. 下载仓库 ZIP 并解压，或克隆仓库。
2. 双击 `Start-CodexDeskHUD.vbs`（或 `.cmd`）。首次启动自动将 `config.example.json` 复制为本地 `config.json`。
3. Docker 默认关闭，需要时在本地 `config.json` 启用并填写配置。

可选：在 Windows PowerShell 中安装到本机：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -DesktopShortcut
# 追加 -AutoStart 可创建开机启动快捷方式。
```

安装位置为 `%LOCALAPPDATA%\CodexDeskHUD`，已有的安装配置会保留。`Uninstall.ps1` 仅删除快捷方式；需要清除设置时，先退出程序，再删除安装目录。

## 配置说明

仓库只包含通用的 [`config.example.json`](config.example.json)。你的机器配置保存在 Git 忽略的 `config.json`，不要提交它。

| 配置项 | 说明 |
| --- | --- |
| `Windows.CodexHome` | 会话根目录；留空使用 Windows 用户目录下的 `.codex`。 |
| `Windows.CodexCommand` | Codex 可执行文件路径；留空尝试自动发现。 |
| `Docker.Enabled` | 是否启用 Docker 来源，默认 `false`。 |
| `Docker.WslDistro` | `wsl -l -q` 中的发行版名称，留空尝试发现。 |
| `Docker.Container` | `docker ps` 中的运行容器名称，留空仅在候选唯一时自动选择。 |
| `Docker.CodexHome` | 容器中的会话根目录，留空使用容器环境或用户目录。 |
| `Docker.CodexCommand` | 通常为 `codex`；若 Docker exec 的 PATH 找不到它，请填写容器内绝对路径。 |
| `RefreshSeconds` / `QuotaRefreshSeconds` | 轮询间隔 / 额度刷新间隔，默认 3 / 90 秒。 |
| `MaxSessionsPerSource` | 每个来源最多展示多少个最近会话，默认 8。 |
| `RunningStaleMinutes` | 无更新的运行会话变为“疑似中断”的阈值，默认 30 分钟。 |

会话目录应与可执行程序使用的账号相对应。当前版本仅修改会话目录不会自动切换额度账号，请让 Codex 进程使用正确的环境。Windows 和 Docker 的额度不会相加；同一账号可能展示两次。

## 使用边界与排错

- 这是早期小工具。任务状态来自日志推断，不保证进程真实存活。长时间无新事件可能显示疑似中断；读取范围外的旧事件可能导致未知状态。来源标签也是启发式判断。
- 后台顺序轮询，先发布会话、后查额度。慢速远端请求仍会推迟下一轮更新，配置间隔不是精确刷新周期。
- 缓存额度可能过时。未返回的窗口不会被当成剩余 100%。实时额度要求对应目标能连接 Codex 服务。
- 每个实例支持一个 Windows 配置目录、一个 WSL Docker 容器，尚不支持直接 SSH 或多容器聚合。
- 若系统禁用 VBS，可用 `Install.ps1` 尝试编译原生启动器，或用 Windows PowerShell 运行 `CodexDeskHUD.ps1`。
- 排错时运行 `Debug-CodexDeskHUD.cmd`，查看 `%LOCALAPPDATA%\CodexDeskHUD\worker.log`。容器网络或代理需要单独配置。
- 容器探针先尝试 Node.js，再尝试 Python 3。Python 成功时，日志中的 Node 错误不一定影响功能。

## 隐私

不添加遥测，不使用项目自建后端。后台读取本地会话元数据和日志尾部，日志可能含会话正文；提取的标题和状态写入本地状态文件。认证和实时额度请求交给 Codex。HUD 不导出凭据、不上传会话记录。日志及截图可能包含路径、任务名或额度，分享前请脱敏。详见 [PRIVACY.md](PRIVACY.md)。

## 开发与验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Core.ps1
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\docs\Render-Demo.ps1
```

离线测试使用虚构数据，不需要登录 Codex、启动 WSL 或读取个人会话。配图脚本使用真实界面控件和虚构数据。欢迎提交改进及脱敏后的复现信息。

MIT 开源协议。独立社区项目，与 OpenAI 无隶属关系。见 [LICENSE](LICENSE)。
