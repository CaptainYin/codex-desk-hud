# Privacy / 隐私

The repository ships only generic configuration. `config.json`, authentication files, JSONL logs, databases and generated binaries are ignored. Do not force-add these files.

At runtime the HUD reads session metadata, a session title index, and rollout tails on the configured Windows/WSL Docker targets. Rollout tails can contain conversation text. It selects lifecycle and token events for display. Derived task names, status and quota snapshots are written under `%LOCALAPPDATA%/CodexDeskHUD`; worker errors may contain paths and server messages. These local files are not anonymous.

The HUD launches the installed Codex app-server for account allowance. Codex uses its existing authentication and network configuration. The HUD has no analytics or project-operated server and does not upload session records or copy authentication files. These statements concern HUD code; installed Codex handles its own networking.

Documentation images use fictional data rendered through the real controls. Before reporting a bug, remove personal paths, task names, account identifiers, credentials and raw conversation text from logs or screenshots.

仓库仅提供通用配置，本机配置、认证文件、日志及数据库均不应提交。运行时读取的日志可能含会话正文，本地状态文件和错误日志也可能包含私人信息。HUD 不上传会话记录，不复制认证文件；实时额度查询由已安装的 Codex 使用现有登录状态完成。文档配图为虚构数据。分享诊断材料前请自行检查并脱敏。
