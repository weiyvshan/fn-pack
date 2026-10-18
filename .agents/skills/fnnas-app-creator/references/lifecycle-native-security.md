# Lifecycle, native runtime, and Docker safety

Read this reference before creating or auditing lifecycle shell code, service
supervision, destructive uninstall behavior, data migration, native/embedded
runtimes, or Docker project status and supply-chain behavior.

## Contents

- [Keep lifecycle failures observable](#keep-lifecycle-failures-observable)
- [Use a safe dispatcher](#use-a-safe-dispatcher)
- [Validate destructive targets](#validate-destructive-targets)
- [Design persistence across every transition](#design-persistence-across-every-transition)
- [Supervise native processes safely](#supervise-native-processes-safely)
- [Root 控制与已验源码](#root-控制与已验源码)
- [systemd 解析与启动边界](#systemd-解析与启动边界)
- [Upgrade fixed-port services safely](#upgrade-fixed-port-services-safely)
- [Audit native binaries and embedded runtimes](#audit-native-binaries-and-embedded-runtimes)
- [Respect fnOS Docker lifecycle ownership](#respect-fnos-docker-lifecycle-ownership)
- [Audit Docker configuration and supply chain](#audit-docker-configuration-and-supply-chain)
- [Final checklist](#final-checklist)

## Keep lifecycle failures observable

Do not allow logging to change a hook's exit status. A pattern such as:

```bash
run_hook 2>&1 | install_log
```

normally returns the logger's status, not `run_hook`'s status, unless the shell
and script deliberately preserve pipeline failure. Prefer capturing output and
status explicitly, or use a tested Bash `PIPESTATUS`/`pipefail` design.

Requirements:

- call a known shell function directly rather than through `eval`;
- capture the function/command status immediately;
- write both stdout and stderr to an installation log;
- copy a concise failure plus useful tail to `TRIM_TEMP_LOGFILE`;
- return the original non-zero status to App Center;
- never end a failed phase with an unconditional `exit 0`;
- keep log writes best-effort so a logging failure does not hide the cause.

A thin phase wrapper must capture stderr as well as stdout:

```bash
#!/bin/bash
. "$(dirname "$0")/installer"
phase="$(basename "$0")"
"$phase" >"${TRIM_TEMP_LOGFILE:?}" 2>&1
```

This example still requires an allowlisted phase and correct error propagation
inside the dispatcher. Do not copy it without those checks.

## Use a safe dispatcher

Lifecycle wrappers can share an installer framework, but dispatch only known
phase names:

```bash
case "$phase" in
  install_init|install_callback|upgrade_init|upgrade_callback|\
  config_init|config_callback|uninstall_init|uninstall_callback)
    "$phase"
    ;;
  *)
    printf '%s\n' "Unsupported phase: $phase" >"${TRIM_TEMP_LOGFILE:?}"
    exit 1
    ;;
esac
```

Root 路径上的包装器只调度已审核阶段，并使用固定命令路径或固定 PATH。上面的示意包装器不适合作为 Root 保护入口直接复制：`dirname`/`basename`、被 source 的 installer 和日志目标均需证明可信，日志失败不得改变原退出码。

Do not source a mutable file as shell code. When persisting wizard values:

- use a format with unambiguous escaping, preferably JSON;
- restrict permissions;
- allowlist keys;
- reject newlines and invalid types where a line format is unavoidable;
- validate values again after loading;
- never persist runtime tokens or authorization headers.

## Validate destructive targets

Before deleting data, resolve an exact non-empty path and prove it belongs to
the application. An unset expansion in commands such as `find $path -delete`
can fall back to the current directory.

Apply all of these guards:

1. require the expected `TRIM_*` variable to be set;
2. reject `/`, `.`, an empty string, a volume root, `/var/apps`, and other
   broad ancestors;
3. resolve symlinks or canonicalize the existing parent;
4. compare the resolved path with an allowlist derived from
   `TRIM_PKGVAR`, `TRIM_PKGETC`, and `TRIM_PKGHOME`;
5. quote the path and use `--` when the command supports it;
6. log the resolved target before deletion without revealing secrets;
7. keep “preserve data” as the default uninstall choice;
8. test empty, missing, symlinked, space-containing, and malicious values.

Do not construct destructive targets from `TRIM_APPNAME` and hard-coded
`/var/apps/...` paths when fnOS already supplies the exact directory.

## Design persistence across every transition

Define expected state for:

每项实机验收都记录控制面任务终态、专属单元属性、PID 的 UID/GID 和 executable/argv、health、固定端口及浏览器入口；省略项须给具体原因，不由静态审计自动判为实机通过。

| Transition | Required decision |
| --- | --- |
| Fresh install | Which defaults are seeded and who owns them? |
| Cold start after complete stop | PID=0/端口释放后再启用，是否正确降权、健康并恢复控制面 running？ |
| Initialization failure | 保留原退出码，错误可定位，未误报运行，旧数据和配置是否保持？ |
| Recovery after failure | 恢复是否限定本应用外部注册/派生状态，是否通过新 FPK 与完整证据重新验收？ |
| Reinstall with preserved data | Which existing values win? |
| Upgrade | What is migrated, backed up, restored, or regenerated? |
| Downgrade | Is it supported, rejected, or restored from a compatible backup? |
| Configuration change | Does it require validation, restart, or Docker recreation? |
| Volume/identity change | How are ownership and links repaired? |
| Uninstall preserve | Which data survives and how is it discovered later? |
| Uninstall delete | Which exact application-owned paths are removed? |

Make transitions idempotent where practical. Do not move packaged defaults
out of `target` without a documented upgrade strategy. Repair ownership only
on application-owned paths and do not hide permission failures with `|| true`
unless the failure is genuinely non-fatal and reported.

## Supervise native processes safely

Device-verified supervision traps:

- Capture the daemon PID directly: `setpriv ... "$BIN" >>log 2>&1 & echo $!`.
  Backgrounding a shell *function* that wraps the launch runs it in a
  subshell, so `$!` records the subshell instead of the daemon and `status`
  misreports the service as running.
- Validate a PID by executable identity before acting on it:
  `readlink /proc/$pid/exe | grep -q <binary-name>`. Use absolute paths
  (`/usr/bin/ss`, `/usr/bin/readlink`) inside hooks — non-login hook shells
  may have a narrow PATH.
- Never run `pkill -f '<path pattern>'` from a lifecycle script or a shell
  one-liner: the pattern matches the caller's own command line and kills the
  caller. Prefer `pgrep -x <exact-name>` plus the identity check above.
- Fixed-port readiness loops must treat "PID died" as an immediate failure
  (break and report), not keep polling; tail the service log into the failure
  message written to `TRIM_TEMP_LOGFILE`.


For PID-file services:

- write the PID only after a successful spawn;
- verify the PID still belongs to the expected executable and application
  identity before signaling it;
- remove stale PID files without killing unrelated processes;
- wait for readiness, not merely process creation;
- return failure when the process exits before becoming healthy;
- send a graceful signal, wait with a deadline, then use a forceful signal only
  for the same verified process;
- avoid broad `pkill -f`; if a compatibility cleanup is required, use an exact
  process identity and document collision risk;
- make `status` distinguish stopped (`3`) from inspection failure (`1`).

For multi-process services, track every child or use a supervisor with a clear
ownership boundary. A single PID plus a global process-name cleanup is not
proof that only this package will be stopped.

## Root 控制与已验源码

将 Root 生命周期与非 Root 长驻服务分开。应用 `etc`/`var` 正常可写，Root 单元和环境文件放入固定、应用专属的外部私有控制目录；验证父目录和最终对象的真实路径、类型、Root 属主、ACL/有效写权限及精确模式。目录 0700、单元 0644、环境文件 0600 是参考合同，保护检查仍须覆盖应用用户及祖先目录；不要泛化 chmod/chown App Center 安装树。

应用用户可写 ACL 的 target 源码不适合直接由 Root `source`、导入或执行。若采用内容绑定的控制器，按以下顺序证明信任链：

1. 受保护外层元数据入口及其祖先由 Root 管理，应用身份没有有效写权限；在该入口固定经审控制器摘要。
2. 通过同一文件描述符以 `O_NOFOLLOW` 打开，检查普通文件、Root 属主、写权限、读取上限；可采用 `O_NONBLOCK` 避免 FIFO 阻塞。允许的 ACL 模型与大小上限由实现合同明确给出。
3. 对限长读取的同一字节缓冲区计算摘要、编译和执行，不校验后再次从路径读取。摘要匹配不替代 Root 控制目录、单元或环境文件的权限检查。
4. 模板与初始化源码也绑定经审摘要；初始化需要应用写权限时，将已验源码缓冲区交给固定应用用户/专用组执行，避免 Root 导入可写运行时或安装依赖。
5. 修改控制器、模板或初始化实现后，在源码中显式同步相应 pin，再审核代码与最终 FPK 的实际字节。重新生成 pin 本身不是审核通过证明。

使用只读 JSON 工具 [check_content_pins.py](../scripts/check_content_pins.py) 检查内容链，异常时停在源码修复阶段；它不自动更新摘要或放宽 AST 合同。

## systemd 解析与启动边界

按指令语法分别编码，不把 shell 引号规则套到整个单元：

| 指令类型 | 实机合同 |
| --- | --- |
| `WorkingDirectory`、`EnvironmentFile` 标量路径 | 整值双引号可能变成路径内容，导致非绝对路径错误；渲染绝对路径字面值并按 systemd 规则保护 `%`。 |
| `ExecStart`、`ReadWritePaths` 参数列表 | 按词列表逐项编码空格、反斜杠、双引号和 `%`，禁止未审提权前缀与额外命令。 |
| 环境文件内容 | 单独使用该文件的编码规则、固定键及类型验证，拒收换行/NUL 等注入边界。 |

渲染后调用目标兼容版本的真实 `systemd-analyze verify --man=no`，覆盖空格、美元符号、百分号、路径内引号及非法换行。解析测试不启动服务，也不覆盖设备现存单元。

`Type=simple` 在 fork 后、用户/组设置与 `execve` 前就可令 `systemctl start` 返回；严格 PID 检查此时可能读到尚未降权的进程。为此类非通知式原生服务固定 `Type=exec`，等系统完成用户/组设置和 `execve` 后返回，再在有界期限内验证 UID/GID、可执行文件/argv、进程存活和应用 health。`Type=exec` 不是业务就绪证明，也不替代健康接口。SDK/目标 systemd 的兼容性须先验证，不通过捕获身份错误、宽泛重试或跳过 PID 校验掩盖竞态。

停服前仍核验专属单元、无外来 drop-in、正确 PID 身份；停服成功需 MainPID=0 且固定端口释放。使用 [check_native_runtime.py](../scripts/check_native_runtime.py) 只读 JSON 检查作为证据的一部分，不让检查器自动启停服务。

## Upgrade fixed-port services safely

incoming `upgrade_init` 在旧 target 替换前执行，启动入口与源码的版本可能不同。内容保护实现只在该前置阶段接受有限、源码中固定、由实际保留旧 FPK 提取并审核的历史摘要；`upgrade_callback`、start/stop/status 和其余阶段只接受当前摘要。保留普通文件/Root 属主/FD 上限/同字节缓冲区执行的全部检查，禁止动态读取环境或可写安装清单作为历史可信集合。

建立入口实际支持的全部阶段 × 当前/逐个历史/未知源码摘要矩阵：当前符合实现合同，历史仅升级前，未知全失败；历史兼容不豁免包内当前源码与固定 AST 的审核。保留原旧 FPK、checksum 和审计结果，以真实字节回归而非伪造摘要。

An upgrade can replace the executable on disk while an old process continues
to serve its socket. This is especially easy to miss when the old PID file is
stored in a temporary directory or when `/proc/<pid>/exe` reports a `(deleted)`
path.

For every native service with a fixed port:

1. Stop all package-owned processes in `upgrade_init`, before the package target
   is replaced. Keep the same stop operation in `upgrade_callback` as a
   defense-in-depth cleanup for a process that survived the first hook.
2. Store current PID files under persistent package state such as `TRIM_PKGVAR`
   and inspect legacy locations during migration. Missing or stale PID files
   must not prevent discovery of an orphan, and must not authorize signaling an
   unrelated process.
3. Verify package UID, expected executable basename, and a canonical path under
   the package directory. Accept the old executable's `(deleted)` suffix only
   after the package-directory and basename checks still pass.
4. Send `TERM`, wait a bounded interval, then send `KILL` only if the same
   verified process remains. Return non-zero if the process cannot be verified
   after the forceful deadline.
5. Check every fixed port after process cleanup. Distinguish “port is free”,
   “port is occupied by an unrelated process”, and “port inspection is
   unavailable”; only the first is a successful stop result.

Do not solve this class of failure by changing the port, deleting a PID file,
or running an unscoped `pkill`/`fuser -k`. Add a regression that replaces a
binary while it is running, exercises legacy and persistent PID paths, and
proves that a nested port check cannot overwrite the caller's failure state.

## Audit native binaries and embedded runtimes

Do not infer native compatibility from `manifest.platform` alone. Inspect the
final `app.tgz` and verify:

- executable format and architecture (`ELF e_machine`, script shebang, or
  equivalent);
- dynamic interpreter and required shared libraries;
- GLIBC/libstdc++ baseline on the oldest supported fnOS;
- executable permission and line endings after packaging;
- runtime search paths and working directory;
- representative native imports or process startup on the target device.

For self-contained .NET, Java, Node, Python, or similar bundles:

- record the embedded runtime and application versions separately;
- remove unnecessary debug symbols only after confirming diagnostics needs;
- include applicable third-party licenses;
- produce or retain an SBOM when distributing many vendored components;
- scan application and runtime dependencies for known vulnerabilities;
- disable unsafe self-update behavior when package upgrades own the files;
- verify package size and every supported architecture.

Static architecture inspection is useful but cannot prove ABI compatibility.
Use `readelf`, `file`, `ldd`, native imports, and service health checks on an
appropriate Linux/fnOS target when risk warrants it.

## Respect fnOS Docker lifecycle ownership

When `config/resource` declares a `docker-project`, fnOS manages Compose project
startup and shutdown. In `cmd/main`:

- keep `start` and `stop` as successful no-ops unless device evidence requires
  a compatibility workaround;
- implement `status` accurately by checking the expected container set;
- return `0` only when required services are running/healthy;
- return `3` when the project is stopped;
- return `1` for inspection or configuration errors;
- do not also run `docker compose up/down` from `cmd/main`, which can race App
  Center ownership.

Use stable `docker-project.projects[].name`, Compose path, and explicit
container names when status logic depends on them. For multi-container apps,
one running container is not sufficient evidence that the app is healthy.

## Audit Docker configuration and supply chain

Cross-check manifest, resource, Compose, UI, protocol files, wizards, and
callbacks for:

- the same host port source of truth;
- valid `1..65535` range and listener availability;
- restart/recreate behavior after configuration changes;
- volume paths inside application-owned or declared resources;
- container UID/GID access to bind-mounted data;
- secrets that are neither packaged nor exposed through UI/logs;
- image architecture and target fnOS Docker compatibility;
- immutable image digest or a documented tag/update policy;
- registry/mirror behavior and offline installation expectations;
- initializer exit code, logs, and expected output artifacts.

Compose 和其他包管理安装产物的持久变更只走源码 → 新版本 → SDK → App Center，回调不热改 installed Compose，也不以手工 compose up/down 接管 App Center 工程。动态配置使用已声明的应用可写状态或受支持的外部设置，并证明读取/重载时序。端口变更还须同步源码中的桌面入口与既有 `.sc` 消费者，仅改 Compose 不会自动更新它们。

## Final checklist

1. Confirm every lifecycle failure reaches App Center with its original status.
2. Reject empty or out-of-scope destructive paths.
3. 在可重置的专用测试环境覆盖 fresh install、完全停止后的 cold start、初始化失败/恢复、交叉版本 upgrade、配置与保数据重装；卸载两种选择使用隔离数据，不拿真实用户数据做删除测试，未实机项明确标待验证。
4. Verify PID/container status identifies only application-owned processes.
5. Match native and image architecture to the manifest and target device.
6. Check runtime libraries, licenses, SBOM/CVE posture, and package size.
7. Keep Docker start/stop ownership with fnOS and verify the whole project.
8. Validate the final FPK and repeat high-risk checks on a dedicated NAS.
