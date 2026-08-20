# AgentHub for macOS

AgentHub 是一个原生 macOS 状态栏应用，也是面向本地 AI Coding Agent 的轻量控制中心。

当前版本聚合显示：

- Codex 周额度剩余百分比与重置时间
- Claude Code 5 小时额度、周额度与重置时间
- 当 Claude Code 周额度耗尽时，5 小时额度同步显示为 0%
- 绿色、橘色、红色圆角进度条状态
- 每 5 分钟自动刷新、手动刷新、登录时启动
- 自动记录当前 Claude Code 与 Codex 登录邮箱及套餐类型
- 本地账号看板：退出或切换账号后仍保留最后额度与重置时间
- 历史账号到达预计重置时间后提示“可切回确认”

状态栏使用 OpenAI 与 Claude 品牌标识，点击即可展开完整信息。

## 安装

在 macOS 终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/RegisonDonut/agent-hub-mac/main/scripts/install.sh | bash
```

该命令会下载同时支持 Apple Silicon 与 Intel Mac 的最新 Release，安装到 `~/Applications` 并启动。

也可以从 [Releases](https://github.com/RegisonDonut/agent-hub-mac/releases/latest) 手动下载安装包。

想先了解功能、安装方式与后续规划，可以打开 [Donut Artifact 分享页](https://d0.getdonut.ai/preview/dcfd02bf-091a-4608-a2e9-513e3649ce24)。该页面已公开，可直接转发给同事。

也可以将本仓库地址交给 Claude Code 或 Codex，并告诉它：

> 请安装并运行这个 macOS 应用，完成后设置为登录时启动。

## 从源码构建

要求 macOS 13 或更高版本、Swift 5.9 或更高版本，并已登录本机 Codex CLI 与 Claude Code。

```bash
git clone https://github.com/RegisonDonut/agent-hub-mac.git
cd agent-hub-mac
./scripts/build-app.sh
open dist/AgentHub.app
```

AgentHub 不保存或上传凭据。Codex 数据来自本机 `codex app-server`；Claude Code 数据通过 macOS 钥匙串中的既有 OAuth 登录读取 usage 接口。账号邮箱、套餐以及最后一次额度快照只保存在 `~/Library/Application Support/AgentHub/accounts.json`。

## Roadmap

- 多账号登录与快速切换
- 本地会话、模型和配置管理
- Agent 健康检查与常见问题修复
- 统一的使用量、成本与权限中心

## Development

```bash
swift test
./scripts/build-app.sh release
```
