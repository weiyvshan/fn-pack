# fnOS App Center 安装交接

将已审计 FPK 交给已注册的 `fnos` 技能执行安装与启停；本参考补充 CLI 与浏览器 UI 的分支和共同验收，不替代 `fnos` 的认证及当前命令文档。

## 目录

- [身份与已有会话](#身份与已有会话)
- [FPK 预检与任务提交](#fpk-预检与任务提交)
- [CLI 转 UI](#cli-转-ui)
- [首装与升级向导](#首装与升级向导)
- [任务终态与真实运行](#任务终态与真实运行)
- [失败定位与窄恢复](#失败定位与窄恢复)
- [只读检查器交接](#只读检查器交接)

## 身份与已有会话

1. 加载 `fnos`，读取其 `entries/trim-app.md` 和 `reference/app-center.md`，按技能 manifest 选择本机支持的 CLI 二进制；示例中的 `TRIM_CLI` 是该二进制的实际路径，不是另一个工具。
2. 优先复用已配置的 OAuth profile，用目标设备上的只读应用查询确认连接和权限；应用名相同不证明设备相同，同时核对已确认的 NAS、安装卷和版本。
3. OneSSH 的 SSH 权限、OneSSH 管理的 fnOS profile、CLI OAuth session 与浏览器 cookies 是独立认证状态。某一层登录成功不代表其他层已登录；只报告状态和目标，不读取/复制密码、token、code 或 cookie 值。
4. CLI session 过期或缺 scope 时，遵循 `fnos` 的交互 OAuth 流程；浏览器需要登录时让用户完成其登录。不要更换凭证后假称同一会话，不把凭证写进参数、日志或文档。
5. 浏览器复用现存目标页与持久任务空间，任务结束不关闭用户登录窗口。新弹窗或网页入口出现时先定位现存标签页，避免重复开页。

```bash
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app list
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app status "${APP_NAME:?}"
```

`PROFILE`、`APP_NAME` 及后续 `VOLUME_ID` 由已确认目标选择，不用凭空默认值。

## FPK 预检与任务提交

先完成现有 SDK/身份/ACL 的只读预检，以及最终 FPK 布局、内容 pin 与原始审计验证，保留版本、字节数和 SHA-256。首装尚未创建的包身份/依赖记录为待 App Center 对应阶段落地后复验，不用猜测值宣称通过。变化的包内容使用新版本，只在工作区/构建目录处理原始与派生产物；installed target/meta/Compose/SDK 都不热改。

NAS 已存有 FPK 时优先远端路径预检，路径是具体 `/vol.../*.fpk`，不是下载 URL 或目录：

```bash
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app install-fpk \
  --remote-path "${NAS_FPK_PATH:?}" --volume-id "${VOLUME_ID:?}" --dry-run --yes
```

`--dry-run` 会解析包并运行安装信息检查，不提交安装任务；本地文件方式仍可能上传暂存包，它不是文件系统零写入承诺。核对解析出的应用、版本、安装/数据卷、依赖、向导与是否立即启动，检查业务响应而非仅 CLI 退出码。

预检没有 UI 决策分支时，再显式提交相同包与卷：

```bash
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app install-fpk \
  --remote-path "${NAS_FPK_PATH:?}" --volume-id "${VOLUME_ID:?}" --yes
```

如需本地文件上传，按 `fnos` 文档使用 `app install-fpk <localFile.fpk>`。默认安装后启动；有明确目的才使用已支持的 `--no-start`。许可证确认、向导 JSON、取消失败任务等选项先核对 `fnos` 当前文档，不编造通用 force、跳过依赖或保数据参数。

## CLI 转 UI

| CLI 检查结果 | 后续路径 |
| --- | --- |
| 许可证要求且未显式接受 | 审阅许可证，使用文档支持的 `--accept-license`，或进入 App Center UI。 |
| 依赖应用安装/更新/启动变化 | 进入 UI 审阅依赖操作；这是 CLI 明确的控制边界，不是 CLI 故障。 |
| 运行中的被依赖应用受到影响 | 在 UI 处理依赖影响，保持 DSH、网关和其启动器运行。 |
| 自定义安装/升级参数需求 | 按文档支持的 `--custom-parameters`/`--api-scope` 提交真实字段，或 UI 完成。 |
| 卷不可用、SDK 损坏、OS 不兼容 | 先只读查明根因，由 App Center 支持流程修复，不在安装树补文件。 |

出现 `app-center start has dependency app changes that require App Center UI` 后，记录该分支并直接转 UI，不重复相同 `app start` guard，不绕过检查。停止是否同样需要 UI 由真实返回决定。

支持的停用命令为：

```bash
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app stop "${APP_NAME:?}" --yes
```

再次启用先按真实依赖分支选择 CLI `app start <appName> --yes` 或 UI，而不是用直接执行已安装脚本、手工 systemctl 接管来替代 App Center 控制面。

## 首装与升级向导

在已登录 App Center 选择已确认卷及相同 FPK，核对实际文件名与版本。每次依据当前 DOM/语义选择器定位，旧快照 ref 与坐标不是持久定位合同。

- 首次安装可出现许可证、安装向导和后续步骤；对真实控件操作并确认 React 状态已变更，再按可见步骤继续。
- 已安装应用的实机升级流程可能在安全确认后直接开始更新；此时观察任务和版本，不等待仅首装才有的 checkbox 或“下一步”。其他 fnOS 版本以当前界面证据为准。
- 错误/确认弹窗先处理，再等待该弹窗实际消失，重新读取状态后定位底层按钮；不要在一次异步渲染间隔内假定弹窗已经关闭。
- 只有已观察到的失败终态才重新提交；任务仍在执行时不重复点击、安装同包或启动第二任务。

## 任务终态与真实运行

CLI 返回的任务 ID 可用已支持的 `app task-status <taskId>` 查询。UI 路径也记录实际终态、错误阶段及版本。`APP_UPDATED`/安装成功只证明包更新，不代表随后启动成功。

```bash
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app status "${APP_NAME:?}"
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app entry list
"${TRIM_CLI:?}" --profile "${PROFILE:?}" app desktop list
```

联合验收 [平台检查矩阵](platform-contract.md#build-install-and-publish-checks)：

| 层次 | 判定证据 |
| --- | --- |
| App Center | 正确包版本、任务终态成功、应用 `running`、符合入口合同的 `isOpen`/entry 信息。`status=start` 不是 running。 |
| systemd | 专属 Fragment/注册和无外来 drop-in、正确 Type/User/Group、loaded/active/running。 |
| 进程 | 非零 MainPID、`/proc` 中 Uid/Gid 四项均与固定 NSS UID/专用 GID 匹配、真实 executable/argv 与所属进程组；不只看端口或 PID 存在。 |
| 业务 | 实际 health 返回预期内容，启动过程没有未处理异常；稍后健康不抹去之前的控制面失败。 |
| 停止/冷启动 | 支持的停服后 MainPID=0 且固定端口释放；再次启用成功并核验新进程，而非对已健康服务幂等启用。 |
| 持久状态 | 配置、数据或 revision 的摘要/mtime/属主/组/模式前后对比，区分应保留业务状态和可重建派生环境。 |
| 浏览器入口 | 从注册入口实际打开目标 URL，页面、关键资源与请求正常；不用直接 curl 代替桌面入口。 |

原始审计零问题、构建成功、版本已登记、socket 存在或服务后来健康，均不是独立的实机通过条件。FPK 版本、SDK 版本与 health 中的上游/API 版本分开记录。未配置外部 API、未实测的业务流程和卸载删除场景分别标记，不为了测试删除真实用户数据。

## 失败定位与窄恢复

保留 task/event ID、当前版本、失败 hook、日志尾部、专属单元与 PID/端口状态。对照 [原生阶段诊断](troubleshooting.md#原生安装与升级阶段诊断)，先解释最早失败处，再改源码发布新包。

`systemctl disable` 不是通用恢复动作。只在已证明这是本应用的外部注册、MainPID=0、没有本应用残留监听、无 foreign 单元/drop-in，并有明确的坏注册/解析故障证据时，评审窄范围撤销本应用注册，然后由 App Center 正常升级；禁止一律 disable、批量清理或覆盖私有控制文件。

保留 `etc`/`var`、配置、数据、venv 与 revision，恢复前后核对内容摘要和元数据；installed target/meta 不写入也不改权限。Root 控制文件正常修复由新 FPK 生命周期负责。永不停止/重启 DSH、网关或其启动器，不采用直接删除安装目录、手工 Compose 重建或修改 SDK 的捷径。

## 只读检查器交接

本技能检查器输出只读 JSON，调用前读取当前实现/帮助确认精确参数：

- [native_preflight.py](../scripts/native_preflight.py)：依赖解释器、架构、身份与权限前提。
- [check_content_pins.py](../scripts/check_content_pins.py)：控制器、模板和初始化源码的内容链一致性。
- [check_native_runtime.py](../scripts/check_native_runtime.py)：当前专属运行状态和证据。
- [validate_skill.py](../scripts/validate_skill.py)：技能入口、资源与本地引用完整性。

将检查器送到目标 NAS 时，先确认 SSH 主机映射、源文件与目标临时工作区实际存在，传输后读回 SHA-256；网关视角的 `localhost` 或主机名称不证明与当前 agent 工作区同机同挂载。原生两个检查器依赖同目录的 `native_checks.py`，一起复制到用户临时工作区，不放进已安装 target。先用普通账户运行 SDK 预检；其他应用的 `/proc`、socket owner 检查需要权限时经 OneSSH 的只读特权执行，不在本地 shell 调用 sudo。完成后只清理本次明确创建、已核对内容的临时文件。

这些工具不提交 App Center 任务、不修复摘要、不写 SDK/安装目录，也不自动启停服务；JSON 检查与 CLI/UI 的实际任务终态共同构成证据。
