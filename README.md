# AgentHub for macOS

AgentHub 是一个原生 macOS Codex 管理器，统一管理官方 Codex 登录、本机多账号池、额度和线路切换。

主要功能：

- 状态栏显示 Codex 周额度；多账号线路取当前可调度账号剩余额度的等权平均值
- 查看 Codex 官方登录账号、周额度和重置时间
- 在原生界面添加多个 Codex 订阅账号，无需进入 Sub2API 管理后台或手动创建 API Key
- 有额度账号按剩余额度从高到低排序；0% 账号按最近重置时间排序
- 新账号添加后立即验证真实额度，未知、失败或耗尽状态不会误标记为可调度
- 一键在“Codex 多账号”与“Codex 官方登录”线路之间切换
- 开启多账号时自动启动 Sub2API、创建内部 Key 并写入 Codex provider；关闭时自动检查并发起官方授权
- 完整安装包内置 Codex CLI 0.149.0 与 Sub2API/PostgreSQL/Redis 离线镜像，无需首次下载服务镜像
- 优先使用用户已经安装的 Codex CLI；只有本机没有 Codex 时才使用 App 内置版本，且不会覆盖现有命令
- 官方额度和多账号池额度均每 5 分钟自动刷新，并同步更新状态栏
- 登录流程和回调输入可跨窗口关闭保留
- 登录时启动、手动刷新、本地服务重启与退出管理
- Sub2API 仅监听 `127.0.0.1:18080`，PostgreSQL 与 Redis 不暴露宿主机端口

## 安装

要求 macOS 13 或更高版本。完整安装包已经包含 AgentHub、Codex CLI 和本地多账号服务镜像。由于 Sub2API 依赖 PostgreSQL 与 Redis，多账号模式仍需要本机安装 Docker Desktop；AgentHub 会自动检测并启动它，Docker 不存在时会显示官方下载按钮。Docker Desktop 本身不随本项目再分发，也不会被静默安装。

```bash
curl -fsSL https://raw.githubusercontent.com/RegisonDonut/agent-hub-mac/main/scripts/install.sh | bash
```

也可以从 [Releases](https://github.com/RegisonDonut/agent-hub-mac/releases/latest) 下载 Universal Binary 安装包。

## 使用

安装后单击 macOS 状态栏中的 OpenAI 图标和额度条，直接进入 Codex 管理中心。

管理窗口包含：

- 当前线路开关
- Codex 官方登录账号与实时额度
- Codex 多账号池
- 添加账号和 OAuth 回调流程
- 各账号启用开关、额度状态与重置倒计时
- 登录时启动、刷新、服务操作和退出

打开“Codex 多账号”开关后，AgentHub 会自动启动本地服务、创建仅供本机使用的内部连接 Key，并把 Codex CLI provider 切换为 `agenthub_multiaccount`；没有账号时可直接继续添加第一个账号。关闭开关会恢复官方 `openai` provider，并检查官方授权：已有授权则直接切回，没有授权才打开 Codex 官方登录页。官方登录凭据和本地账号池都不会被删除。切换对新启动的 Codex 会话生效。

App 首次运行会在 `~/.local/bin/codex` 不存在时创建一个指向内置 Codex CLI 的符号链接；不会覆盖用户已经安装的 Codex 命令。

## 本地服务与数据

AgentHub 内置并固定使用 Sub2API `v0.1.179`，其编排文件和本机密钥位于：

```text
~/Library/Application Support/AgentHub/Sub2API/
```

容器数据保存在 Docker 命名卷 `agenthub-sub2api_*` 中。本地 Responses API 地址为：

```text
http://127.0.0.1:18080/v1/responses
```

内部 Key 限制为 `127.0.0.1` 与 `::1` 来源，保存在权限为 `600` 的本地密钥文件中。Docker 端口固定绑定 loopback；如果实际绑定变成 `0.0.0.0`、局域网地址或其他非本机地址，AgentHub 会停止服务并显示安全错误。

> 风险提示：多账号模式会把用户主动添加的 Codex OAuth access token 和 refresh token 保存在本机 PostgreSQL，并通过 ChatGPT Codex backend 转发订阅流量。这不是 OpenAI 公布的通用订阅 API，可能违反上游条款并导致账号受限。请只添加属于自己的账号，不要公开本地端口。

## 从源码构建

```bash
git clone https://github.com/RegisonDonut/agent-hub-mac.git
cd agent-hub-mac
./scripts/build-app.sh
open dist/AgentHub.app
```

要生成包含双架构 Codex CLI 和双架构容器镜像的完整安装包，先运行：

```bash
./scripts/prepare-bundled-runtime.sh
./scripts/build-app.sh release
```

第三方组件版本、许可证和对应源代码地址随 App 保存在 `Contents/Resources/BundledRuntime/`。
