# fnOS application troubleshooting

Read this reference when a build, App Center install, lifecycle script, UI, or
FN Connect path fails.

## Contents

- [Preserve evidence before changing the package](#preserve-evidence-before-changing-the-package)
- [Distinguish source, artifact, and device copy](#distinguish-source-artifact-and-device-copy)
- [Understand the archive layers](#understand-the-archive-layers)
- [App Center install failures](#app-center-install-failures)
- [Start and health failures](#start-and-health-failures)
- [原生安装与升级阶段诊断](#原生安装与升级阶段诊断)
- [恢复范围与数据保留](#恢复范围与数据保留)
- [Package identity and artwork](#package-identity-and-artwork)
- [FN Connect and WebSocket](#fn-connect-and-websocket)

## Preserve evidence before changing the package

Capture:

- full command and arguments, excluding secrets;
- FPK filename, version, byte size, and SHA-256;
- App Center code, backend `text`, request/task ID, and timestamp;
- device fnOS version, architecture, target volume, and dependency state;
- packaged manifest and nested `app.tgz` size;
- `TRIM_TEMP_LOGFILE` text and relevant service/install log tail.

An `appcenter-cli` panic after an App Center error may be a nil-handling bug in
the CLI. Diagnose the earlier backend error first.

## Distinguish source, artifact, and device copy

These are different objects:

1. working source tree;
2. newly built local FPK;
3. file uploaded to the device;
4. App Center's parsed/extracted copy;
5. installed application directories.

Compare immutable evidence across them. A matching app name is not enough.
所有持久行为修复走源码修改 → 新版本号 → fnpack SDK → App Center 安装/升级；安装目录只读检查，不旁置备份、不覆盖文件、不改权限。保持原始产物和派生产物分离，不通过重启 DSH、网关或其启动器验证变更。
Same-version rebuilds can collide with cache or an older manually copied file.
Once changed packaged bytes are uploaded, installed, shared, or retained as a
handoff, use a new manifest version and a versioned handoff filename. A private
disposable local build may reuse the current version only while it remains
outside that artifact boundary and is tracked by byte size and SHA-256.

## Understand the archive layers

The outer FPK normally contains `app.tgz`, manifest, lifecycle scripts,
configuration, wizard files, icons, and license metadata. Application files
such as `wheels/` live inside `app.tgz`.

Therefore:

- “no wheels directory” in an outer FPK listing is expected;
- inspect `app.tgz` before concluding dependencies are absent;
- compare `app.tgz` sizes when identifying which build the device used.

## App Center install failures

When the install callback returns non-zero, App Center may roll back the target
and remove the persistent install log. Lifecycle scripts should write:

1. a short explanation;
2. the last useful lines of the failed command;
3. a next action;

to `TRIM_TEMP_LOGFILE` before exiting. Avoid messages that only say “see
install.log”.

依赖应用“已登记”不证明 SDK target 存在或解释器可执行。先检查 symlink 最终目标、SDK 版本与架构、加载器/共享库，并在已准备的应用环境中使用代表性 import；Python 检查关闭字节码写入。不要在预检中安装系统包、修改 SDK 或运行应用初始化。完整只读流程见 [依赖与运行时](platform-contract.md#dependencies-and-runtimes)。

For dependency failures, determine whether the missing package is:

- absent from the wheelhouse;
- present but incompatible with Python/ABI/platform;
- skipped during wheelhouse creation because of a host-platform marker;
- present but unable to load a shared library on fnOS.

For Docker-template applications, distinguish these closely spaced stages:

| Evidence | Likely stage | First action |
| --- | --- | --- |
| `App initialization script error` | `install_init` returned non-zero | Replay only validation with the actual wizard keys; check unset `TRIM_*` variables and avoid durable writes here. |
| `env file ... not found` during install | Compose parsed before the file-producing callback | Remove the late-generated `env_file`, package it earlier, or inject validated wizard values directly. |
| Dependency containers cannot source a generated file | Runtime initializer contract | Inspect initializer exit code and logs; verify the file in the final bind mount, not merely that the initializer is `exited`. |
| App Center reports success but services restart | Compose was accepted, runtime failed | Inspect each container separately, starting with the earliest shared dependency. |

An `exited` one-shot container is ambiguous: exit code zero and the expected
artifact are both required evidence. When PostgreSQL and Redis both fail on the
same missing secret file, investigate their common initializer or mount before
editing either database service.

Before rebuilding, inspect the final `app.tgz` and assert that obsolete absolute
paths and old `env_file` directives are absent. A source-tree edit is not proof
that the packaged Compose changed.

## Start and health failures

Read [lifecycle-native-security.md](lifecycle-native-security.md) before
editing shared lifecycle frameworks, destructive uninstall code, native
service supervision, or Docker project ownership.

Check in this order:

1. application executable and configuration exist;
2. service port is free and matches `TRIM_SERVICE_PORT`;
3. PID/status logic identifies only the intended process;
4. process remains alive;
5. health endpoint returns the expected status;
6. service log contains the actual startup exception.

Return `3`, not `1`, when status simply means stopped.

## 原生安装与升级阶段诊断

先记录实际钩子、任务/事件、包版本与源码摘要，再按最早失败阶段定位；进程稍后健康不消除 App Center 的启动失败。

| 证据 | 先检查 |
| --- | --- |
| 依赖已登记但解释器缺失/不可运行 | SDK symlink 最终目标、解释器版本/架构、加载器及代表性 import；只读预检，不手工补安装树。 |
| `TRIM_GID` 不匹配 | NSS 专用应用组与用户主组是否不同；以 `TRIM_GROUPNAME` 的专用组核验，不用 `id -g` 代替。 |
| `TRIM_PKGETC` 被误要求 Root 私有 | 应用配置可写与 Root 控制文件是否混放；在源码设计外部应用专属 Root 私有控制目录。 |
| Root owner/775 仍被应用用户写入 | ACL、父目录和应用身份有效权限；采用经审受保护入口和同缓冲区内容绑定，不删除完整性检查。 |
| `WorkingDirectory`/`EnvironmentFile` 非绝对路径 | 标量路径是否误套整值引号；先对最终渲染单元做真实 systemd 解析。 |
| 冷启动立即 UID 错误、稍后同 PID 正常 | `Type=simple` 的 fork 早返回；修复为已验证的 exec 边界，保持 UID/GID/argv/health 校验。 |
| `upgrade_init` 当前 pin 不匹配 | 新包元数据是否正面对旧 target；核对保留的旧 FPK，仅升级前允许固定经审历史摘要。 |
| 已登记版本但 `status=start`/入口关闭 | 安装和启动任务的终态、App Center `running`、专属单元、实际 PID、端口和 health 是否共同成功。 |

CLI 提示依赖变更要求 UI 时进入 [App Center 交接](fnos-app-center-handoff.md)，不要重试相同启动 guard。只读 JSON 工具 [native_preflight.py](../scripts/native_preflight.py)、[check_content_pins.py](../scripts/check_content_pins.py)、[check_native_runtime.py](../scripts/check_native_runtime.py) 分别检查依赖与身份前提、源码内容链和当前运行证据；不猜参数，不把工具成功代替应用任务终态。

## 恢复范围与数据保留

`systemctl disable` 不是通用安装失败修复。先读取日志、专属单元/注册链接、父路径、drop-in、MainPID 和端口；若 PID 或归属尚未证明，停在只读调查。只有确认待处理的是本应用的外部注册、MainPID=0、无本应用残留监听且有明确解析/注册故障证据时，才可评审窄范围撤销该注册，让 App Center 正常新版本升级。

保留应用数据、私有配置、venv 与修订标记；不清空 `var`/`etc`，不修改 installed target/meta，不批量移除单元或 foreign drop-in。外部控制内容的正常修复仍由新包生命周期完成。失败恢复前后记录 revision/配置的摘要、mtime、属主、组和模式，并对比新任务终态；必要检查失败应如实保留，不将“服务稍后启动”写成恢复成功。

## Package identity and artwork

Use a new package version for every changed revision sent to a device or
another consumer. Documentation, skill, eval, research, and build-note changes
that do not enter the FPK need no increment, and source-only edits may defer it
until a changed artifact is handed off. If the package uses an independent
release series such as `1.00`, `1.01`, record the upstream application or image
version separately rather than forcing the manifest version to match it.
Compare the device upload by filename, byte size, SHA-256, and packaged
manifest.

Do not accept the `fnpack create` placeholder icons as finished artwork. Prefer
the upstream project's logo, render the required 64 and 256 pixel PNGs, and
verify both the outer package icons and desktop UI copies. Preview at least the
256 pixel output; matching dimensions alone does not prove the correct artwork.

## FN Connect and WebSocket

`localhost` is evaluated by the browser. It refers to the user's computer or
phone unless the browser itself runs on the NAS.

Use:

- LAN: `http://<nas-ip>:<port>/...` with
  `ws://<nas-ip>:<port>/<ws-path>`;
- HTTPS relay/reverse proxy: `https://<public-host>/...` with
  `wss://<public-host>/<ws-path>`.

Prefer deriving the WebSocket scheme and host from `window.location`.

In browser developer tools, inspect the WebSocket handshake:

| Result | Meaning |
| --- | --- |
| `101 Switching Protocols` | proxy path works; inspect app handshake/token |
| `401/403` | relay/proxy session or application authentication failed |
| `200/301/302` | routed as ordinary HTTP or redirected; inspect proxy path |
| TLS/DNS/connect failure | public endpoint is not reachable or trusted |

Keep FN Connect authentication and application authentication separate. A user
may be logged into FN Connect but still need the application's administrator
token. Third-party app relay access can also depend on the FN Connect browser
extension and its current session.

If the relay does not support the application's WebSocket, open the whole UI
through a LAN/VPN address or use an HTTPS reverse proxy configured to forward
WebSocket Upgrade headers. Do not mix an HTTPS UI with insecure `ws://`.
