# AgentHub for macOS

AgentHub 是一个原生 macOS Codex 管理器，统一管理官方 Codex 登录、本机多账号池、额度和线路切换。

主要功能：

- 状态栏显示 Codex 周额度；单击状态栏图标直接打开管理窗口
- 查看 Codex 官方登录账号、周额度和重置时间
- 在原生界面添加多个 Codex 订阅账号，无需进入 Sub2API 管理后台或手动创建 API Key
- 有额度账号按剩余额度从高到低排序；0% 账号按最近重置时间排序
- 新账号添加后立即验证真实额度，未知、失败或耗尽状态不会误标记为可调度
- 一键在“Codex 多账号”与“Codex 官方登录”线路之间切换
- 登录流程和回调输入可跨窗口关闭保留
- 登录时启动、手动刷新、本地服务重启与退出管理
- Sub2API 仅监听 `127.0.0.1:18080`，PostgreSQL 与 Redis 不暴露宿主机端口

## 安装

要求 macOS 13 或更高版本。多账号模式需要安装并启动 Docker Desktop。

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

添加首个多账号后，AgentHub 会自动创建仅供本机使用的内部连接 Key，并把 Codex CLI provider 切换为 `agenthub_multiaccount`。关闭多账号线路时只会恢复官方 `openai` provider，不会删除官方登录凭据或本地账号池。切换对新启动的 Codex 会话生效。

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
