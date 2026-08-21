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
- 历史额度明确标记为“上次记录”并降灰，不冒充实时状态
- 按 Claude Code / Codex、可用状态和邮箱筛选账号
- 当前账号、预计已刷新账号和等待重置账号自动排序
- 历史账号卡片悬停高亮，点击后由 AgentHub 在后台启动官方网页登录
- Claude Code 网页若显示一次性登录代码，可直接粘贴到账号卡片；代码仅转交给本次官方 CLI 进程，不会保存
- Claude Code 切换前先退出本地旧会话，并在授权后校验实际登录邮箱
- Claude Code 登录在隐藏 PTY 中运行，确保网页授权结果能够自动回调 CLI
- 登录授权可随时取消，关闭网页后也不会无限停留在“登录授权中”
- 登录成功后自动刷新看板，全程不打开 Terminal
- 自动把 macOS 系统 SOCKS/HTTPS 代理传给 Codex 后台进程
- Codex 额度请求失败时自动进行三次退避重试
- App 启动时自动启动本机 Codex 多账号引擎、PostgreSQL 与 Redis 服务
- 原生 Codex 多账号窗口：生成官方登录链接、接收回调链接并直接添加账号
- 首个账号添加成功后自动创建内部连接 Key 并启用多账号线路，无需用户接触 API Key
- OAuth 登录步骤保存在 App 级状态和本地临时文件中，菜单卡片关闭后不会丢失
- 多账号可分别启用或停用，并展示周额度与预计重置时间
- 新账号添加后自动验证真实额度；额度未知、请求失败或已耗尽时绝不标记为可调度
- Sub2API 仅监听 `127.0.0.1:18080`，数据库与 Redis 不暴露宿主机端口
- 固定使用 Sub2API `v0.1.179`，服务数据保存在 Docker 命名卷中

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

要求 macOS 13 或更高版本、Swift 5.9 或更高版本，并已登录本机 Codex CLI 与 Claude Code。使用 Sub2API 管理器还需要安装并启动 Docker Desktop。

```bash
git clone https://github.com/RegisonDonut/agent-hub-mac.git
cd agent-hub-mac
./scripts/build-app.sh
open dist/AgentHub.app
```

Codex 状态数据来自本机 `codex app-server`；Claude Code 数据通过 macOS 钥匙串中的既有 OAuth 登录读取 usage 接口。账号邮箱、套餐以及最后一次额度快照只保存在 `~/Library/Application Support/AgentHub/accounts.json`。

AgentHub 的普通账号看板和官方 CLI 登录切换不会复制、保存或回写 Claude Code / Codex 的 access token 或 refresh token。点击历史账号时，App 只在后台调用官方 CLI 登录命令并等待浏览器授权完成；Claude Code 会先退出本地旧会话、预填历史邮箱。当前 Claude CLI 可能要求把网页显示的一次性登录代码粘贴回 CLI，AgentHub 会在卡片中提供输入框并直接转交给等待中的官方进程，随后核对实际邮箱。Codex 由官方网页选择账号。授权过程最长等待 5 分钟，也可以直接点击卡片右上角的取消按钮。

## Codex 多账号模式

AgentHub 1.4 起可以托管一个仅供本机使用的 Sub2API 栈。首次启动会下载固定版本的 Sub2API、PostgreSQL 和 Redis 镜像，并生成独立的管理员密码、数据库密码、JWT 密钥和 TOTP 密钥。编排文件与密钥文件位于：

```text
~/Library/Application Support/AgentHub/Sub2API/
```

容器数据保存在 Docker 命名卷 `agenthub-sub2api_*` 中。打开状态栏面板并点击 `Codex 账号` 即可进入独立的原生多账号窗口；用户不会看到上游管理网页、管理员登录、API Key 创建或分组配置。添加账号时，AgentHub 会生成官方 OAuth 链接，用户完成网页登录后把浏览器地址栏中的回调链接粘贴回窗口即可。登录会话最长保留 30 分钟，关闭状态栏卡片或重新打开管理窗口不会丢失步骤。本地 Responses API 地址为：

```text
http://127.0.0.1:18080/v1/responses
```

内部连接 Key 由 AgentHub 自动创建，并限制为 `127.0.0.1` 与 `::1` 来源。Key 保存在 AgentHub 本地数据目录的 `codex-api-key.secret` 中，文件权限固定为 `600`；`~/.codex/config.toml` 只声明 `agenthub_multiaccount` provider，Codex 通过本地凭据辅助脚本读取 Key，配置文件中不保存 Key 明文。

首个账号添加成功后，AgentHub 会自动启用多账号线路。状态栏面板和管理窗口也提供 `Codex 多账号模式` 开关；关闭时只把 provider 切回官方 `openai`，不会删除官方登录凭据或本地账号池。切换对新启动的 Codex 会话生效。

Docker 端口固定绑定到 loopback，PostgreSQL 与 Redis 完全不发布宿主机端口。AgentHub 启动服务时会验证一次 Docker 的实际绑定；如果发现 Sub2API 被改为 `0.0.0.0`、局域网地址或其他非本机绑定，会立即停止容器并显示安全错误。每次启动还会把编排文件恢复为内置安全模板。运行期间只保留每 60 秒一次的轻量健康检查，用于更新界面状态。

> 风险提示：Codex 多账号模式内部使用 Sub2API，并会把通过该模式添加的 OAuth access token 和 refresh token 原样保存在本地 PostgreSQL 中，再通过 ChatGPT 的 Codex backend 转发订阅流量。这不是 OpenAI 公布的通用订阅 API，可能违反上游条款并导致账号受限。请只添加属于自己的账号，不要公开本地端口。原有 AgentHub 官方 CLI 登录流程仍不会读取或保存 Token；只有主动添加到多账号模式的账号才会进入本地数据库。

## Roadmap

- 账号删除、重新授权和更细粒度的调度优先级
- 本地会话、模型和配置管理
- Agent 健康检查与常见问题修复
- 统一的使用量、成本与权限中心

## Development

```bash
swift test
./scripts/build-app.sh release
```
