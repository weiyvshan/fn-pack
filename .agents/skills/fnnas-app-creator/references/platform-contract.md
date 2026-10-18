# fnOS application platform contract

Read this reference when creating or auditing package structure, manifest,
privileges, resources, entry routing, wizards, dependencies, runtimes, icons,
or the local build/install workflow. It is a portable offline baseline
distilled from the official fnOS developer documentation. Consult the official
documentation for exact fields introduced after this bundled snapshot.

## Contents

- [Compatibility baseline](#compatibility-baseline)
- [Package and installed layout](#package-and-installed-layout)
- [Lifecycle contract](#lifecycle-contract)
- [Manifest](#manifest)
- [Environment variables](#environment-variables)
- [Privileges and resources](#privileges-and-resources)
- [Choose an access model](#choose-an-access-model)
- [Application entries](#application-entries)
- [Wizards](#wizards)
- [Dependencies and runtimes](#dependencies-and-runtimes)
- [Icons](#icons)
- [Build, install, and publish checks](#build-install-and-publish-checks)

## Compatibility baseline

- Use `platform`, not the deprecated historical `arch` manifest field.
- Treat `x86`, `arm`, and `all` as the documented platform values.
- Use `all` only when the package contains no architecture-specific binary;
  Docker images and native dependencies must still support the target device.
- Set `os_min_version` and any `os_max_version` from tested behavior rather
  than optimistic compatibility.
- 分发 SDK 二进制时同时核对内容 SHA-256 与 Git 索引 `100755` 执行位；fnOS/共享文件系统的 `core.filemode=false` 可能令现场可执行文件被初次记录为 `100644`。仅当前文件现场能执行不证明新检出可执行；需要时对已确认的工作区 SDK 使用 `git update-index --chmod=+x -- <sdk>`，不对安装树 chmod。
- The bundled documentation advertises fnpack 1.2.3. Resolve it through
  `scripts/resolve-fnpack.sh`: Windows x64 uses `bin/fnpack.exe`, while native
  Linux and WSL x86-64 use `bin/fnpack-1.2.3-linux-amd64`. Do not infer an
  executable's version from the documentation when the binary cannot report
  one.
- 使用 `micro_app`、TrimApp 或后端 Open API 时，按目标 fnOS 版本查官方开发文档的能力与授权范围；本技能不附带完整 Open API 参考。
- 保留社区包的现有兼容扩展。修改未文档化字段前，用目标机实际配置与行为证明其消费者和作用，不把既有社区用法直接推广为新包标准。

## Package and installed layout

Keep the package root shaped like this:

```text
app/
cmd/
config/
  privilege
  resource
wizard/
manifest
ICON.PNG
ICON_256.PNG
LICENSE
```

fnOS installs the application under `/var/apps/{appname}` and creates or links:

- `target`: App Center 管理的安装产物，按包管理契约禁止热改；这不是文件系统只读证明；
- `etc`: application configuration;
- `var`: persistent runtime data and logs;
- `tmp`: temporary data;
- `home`: application-user data;
- `meta`: package metadata;
- `shares`/share links: declared user-visible shared directories;
- `cmd`, `config`, `manifest`, `wizard`, and icons.

Never choose a volume path manually when a `TRIM_*` path exists. Put mutable
configuration in `etc`, durable data in `var` or a declared share, and
disposable files in `tmp`.

实机权限边界：App Center 可给 `target`、`etc`、`var` 添加应用 UID 的可写 ACL。TripStar 实机的 `target` 虽为 `root:root`，ACL 掩码仍令模式从 755 变为 775；属主和模式并不证明应用用户失去写权限。读取 ACL 并验证应用身份对文件、父目录、SDK 和祖先路径的有效权限，保留设备与版本证据，勿推定所有 fnOS 都有同一 ACL。

精确文件可读不等于每级祖先目录都可列举。Linux/fnOS 的目录 FD 逐级读取使用 `O_PATH|O_DIRECTORY|O_NOFOLLOW`，只要求必要的路径搜索权限；末端文件仍按 `O_NOFOLLOW`、普通文件类型及限长读取验证。不要为修复只读检查器的 `O_RDONLY` 目录误报扩大 ACL 或 chmod/chown。

`etc`/`var` 正常承载应用可写配置和数据。需要 Root 单元或环境文件时，采用已审核、固定应用专属的外部 Root 私有命名空间，例如 `/etc/fnos-<appname>`；逐级验证真实路径、类型、Root 属主和有效写权限，目录 0700、单元 0644、环境文件 0600。这不是批量修改 App Center 目录权限的理由。Root 读取可由应用用户写入的安装源码时，按 [Root 控制与已验源码](lifecycle-native-security.md#root-控制与已验源码) 建立受保护入口与已审核内容指纹。

安装目录的任何持久变更走源码 → 增加发布版本 → fnpack SDK → App Center 安装/升级；禁止设备侧覆盖、旁置备份或 chmod/chown 安装产物。运行控制与包内容变更分开处理，保留原产物，不重启 DSH、网关及其启动器。

Device-verified layout facts:

- `app.tgz` contents extract to the installed package root. A file packaged as
  `app/daemon` resolves to `$TRIM_APPDEST/daemon` at runtime — never reference
  `$TRIM_APPDEST/app/...` in lifecycle scripts or entry URLs.
- fnpack requires every lifecycle phase file to exist (`cmd/install_init`,
  `install_callback`, `upgrade_init`, `upgrade_callback`, `uninstall_init`,
  `uninstall_callback`) in addition to `cmd/main`. Implement them as thin
  wrappers that `exec` the shared dispatcher with their phase name; bare
  symlinks to `main` fail because `$1` arrives as the phase name.
- The `fnpack build` output `<appname>.fpk` lands in the **process working
  directory**, not the project directory. `cd` to the output location first,
  rename the artifact in the same step, and never run `rm <appname>.fpk` in
  the same shell chain that just built it.

## Lifecycle contract

Support these scripts when the corresponding phase is needed:

| Script | Phase |
| --- | --- |
| `install_init` / `install_callback` | before / after package files install |
| `upgrade_init` / `upgrade_callback` | before / after package upgrade |
| `uninstall_init` / `uninstall_callback` | before / after package removal |
| `config_init` / `config_callback` | before / after configuration changes |
| `main` | `start`, `stop`, and `status` |

实机交叉版本契约：

| 阶段 | 可依赖的安装状态 |
| --- | --- |
| `install_init` | target/SDK 调用所需文件可能尚未落地；仅做适合前置阶段的校验，不导入待安装 target。 |
| `install_callback` | 新 target 已解包，再初始化派生运行时及安装专属控制文件。 |
| `upgrade_init` | incoming 新包的元数据脚本面对旧 target；先按旧版本已审核合同停服，不把“新脚本 + 旧源码”误当篡改。 |
| `upgrade_callback` | 新 target 已替换；仅当前版本内容链生效，再准备、启动并验收。 |
| `uninstall_init` | target 尚在，完成归属核验、停服、专属注册移除与保数据决定。 |
| `uninstall_callback` | target 可能已删除；清理设计不依赖该路径的代码或解释器。 |

若 Root 入口校验控制器 pin，仅 `upgrade_init` 允许源码中固定的、已保存实际 FPK 且经审的历史摘要；其他阶段仅当前摘要。未知摘要全部失败，不从环境、安装树或可写清单生成兼容集合。详见 [升级固定端口服务](lifecycle-native-security.md#upgrade-fixed-port-services-safely)。

Make lifecycle scripts idempotent where practical. For `cmd/main`, return:

- `0` for successful `start`/`stop`, and for a running `status`;
- `3` when `status` means stopped;
- `1` for an actual failure or unsupported action.

Set `ctl_stop=false` for static/configuration-only apps that should not expose
start/stop controls. 非零退出前尽力向已验证来源、路径与类型的 `TRIM_TEMP_LOGFILE` 写简明、无秘密的原因；Root 在日志目标尚未验证或 SDK 缺失时只写 stderr，保持原退出码，不为日志跟随未经验证的路径。

When `config/resource` declares a `docker-project`, fnOS normally owns project
startup and shutdown. Keep `cmd/main start` and `stop` as successful no-ops and
make `status` inspect the required containers accurately. Do not also run
`docker compose up/down` unless target-device evidence proves that a documented
compatibility workaround is required. Follow
[lifecycle-native-security.md](lifecycle-native-security.md) for failure
propagation, destructive cleanup, native supervision, and Docker details.

## Manifest

Validate these groups:

| Group | Fields and rules |
| --- | --- |
| Identity | `appname`, `version`, `display_name`, `desc`, `source=thirdparty` |
| Platform | `platform=x86|arm|all` |
| Publisher | `maintainer`, `maintainer_url`, `distributor`, `distributor_url` as applicable |
| Compatibility | `os_min_version`, optional `os_max_version` |
| Runtime control | `ctl_stop` |
| Install | `install_type`, `install_dep_apps` |
| Desktop | `desktop_uidir`, `desktop_applaunchname` |
| Port | `service_port`, `checkport` |
| Authorization | `disable_authorization_path` |
| Updates | `changelog` |

Additional rules:

- Leave `install_type` empty for user-selected storage; use `root` only when
  the system partition is actually required.
- Separate dependencies with `:` and use `name>version` for a minimum version.
- Dependencies prepare from right to left. Dependency resolution is not
  recursive, so declare every direct requirement even when another dependency
  also declares it.
- Copy dependency names exactly from each dependency's own `manifest`
  `appname` field (verify on a device with
  `grep ^appname /var/apps/<dir>/manifest`); a directory name is not
  necessarily the appname.
- Make `desktop_applaunchname` exactly match an entry ID in
  `app/{desktop_uidir}/config`.
- Use `service_port` only for a fixed host port. `checkport` defaults to true.
- Hide authorization-path configuration with
  `disable_authorization_path=true` only when the app does not need user-selected
  file or directory access.
- Keep `maintainer` as the application developer/team and `distributor` as the
  FPK publisher. Obtain both from explicit user or project input; never default
  either field to the skill author, local account, Git identity, or repository
  owner. Optional build-time inputs such as `FNNAS_DISTRIBUTOR` must be
  materialized to literal values before packaging.
- Increment `version` before changed packaged bytes are uploaded, installed,
  shared, published, or retained as a release/test handoff. Repository-only
  documentation or tooling changes that do not enter an FPK do not require an
  increment, and source-only work may defer it until an artifact boundary.
- Preserve unfamiliar existing manifest fields until their consumer and
  compatibility behavior are identified; do not invent them for new packages.

## Environment variables

Use the documented environment rather than reconstructing state:

| Category | Variables |
| --- | --- |
| Package | `TRIM_APPNAME`, `TRIM_APPVER`, `TRIM_OLD_APPVER`, `TRIM_APP_STATUS` |
| Paths | `TRIM_APPDEST`, `TRIM_PKGETC`, `TRIM_PKGVAR`, `TRIM_PKGTMP`, `TRIM_PKGHOME`, `TRIM_PKGMETA`, `TRIM_APPDEST_VOL` |
| Package identity | `TRIM_USERNAME`, `TRIM_GROUPNAME`, `TRIM_UID`, `TRIM_GID` |
| Current script identity | `TRIM_RUN_USERNAME`, `TRIM_RUN_GROUPNAME`, `TRIM_RUN_UID`, `TRIM_RUN_GID` |
| Network/resources | `TRIM_SERVICE_PORT`, `TRIM_DATA_SHARE_PATHS`, `TRIM_DATA_ACCESSIBLE_PATHS` |
| Open API | `TRIM_API_TOKEN` |
| Diagnostics/temp | `TRIM_TEMP_LOGFILE`, `TRIM_TEMP_UPGRADE_FOLDER`, `TRIM_PKGINST_TEMP_DIR`, `TRIM_TEMP_TPKFILE` |
| System | `TRIM_SYS_VERSION`, version components, `TRIM_SYS_ARCH`, `TRIM_KERNEL_VERSION`, `TRIM_SYS_MACHINE_ID`, `TRIM_SYS_LANGUAGE` |

`TRIM_UID`/`TRIM_GID` 是包专用身份，`TRIM_RUN_UID`/`TRIM_RUN_GID` 是当前脚本身份，分开核验。`TRIM_GID` 对应 NSS 中的专用 `TRIM_GROUPNAME`，不等于用户主组的 `id -g`。例如用户主组可为 `AppUsers`，专用应用组仍为另一个 GID；按经审核的固定用户名/组名查询 `pwd`/`grp` 或 NSS，检查 UID/GID 非零且精确匹配，再让初始化和 systemd 显式使用该用户/专用组。

Wizard fields become same-named environment variables without a `TRIM_`
prefix. Quote shell expansions, verify directories before use, and validate
all wizard/request values again at the consumption boundary.

## Privileges and resources

Default to a dedicated package identity:

```json
{
  "defaults": { "run-as": "package" },
  "username": "myapp",
  "groupname": "myapp"
}
```

Use `join-groups` only for required system-group resources such as video or
render devices. Use root only when a narrower resource declaration, group, or
authorization cannot work; lower the long-running user-facing service to the
package user.

Declare only used resources in `config/resource`:

- `data-share.shares`: user-visible directories. They use Windows ACL, not
  POSIX ACL. fnOS grants the package user access automatically. Add `permission`
  only for another explicit user/application (`rw` or `ro`).
- `usr-local-linker`: stable application-specific `bin`, `lib`, or `etc`
  interfaces linked below `/usr/local`; avoid generic command names.
- `docker-project.projects`: stable Compose project names and paths relative
  to `app/`, each containing `docker-compose.yaml`.
- `api-scope`: Open API 能力，按官方目标版本文档核验真实需求及授权范围，不照抄其他包的 scope。

Existing community packages may also contain `port-config`, a protocol `.sc`
file, or `systemd-unit`. 保留这些兼容扩展，先核验设备消费者与运行行为，再用本技能的 [排障与证据流程](troubleshooting.md) 审查，不直接删改已安装产物。

Keep internal state in application directories. Create a data share only when
users or another application need to see or manage that data.

## Choose an access model

| Model | Use when | Authentication and constraints |
| --- | --- | --- |
| Port service | The app exposes its own HTTP service and does not need NAS login context | Configure protocol/port; app owns authentication |
| `index.cgi` | Small static/lightweight HTTP app or compatibility package | NAS checks login before CGI; protocol/port are ignored; no WebSocket, streaming, or long requests |
| Unified gateway | Long-running service, API, NAS login context, or WebSocket | Stable `/app/{appname}` path forwards to a Unix socket and supplies user headers |

For CGI, place an executable `app/{desktop_uidir}/index.cgi` behind
`/cgi/ThirdParty/{appname}/index.cgi/`. Reject traversal and never interpolate
request paths into shell commands.

For the unified gateway, configure `gatewayPrefix` and a filename-only
`gatewaySocket`; the socket lives under `TRIM_APPDEST`. Ignore `protocol` and
`port` for gateway routing. Bind HTTP and WebSocket routes below the registered
prefix. Treat `X-Trim-Userid`, `X-Trim-Isadmin`, and `X-Trim-Username` as
gateway-provided identity only after the request arrived through the gateway,
then apply application business authorization. Never trust a client-supplied
UID in HTTP or WebSocket messages.

## Application entries

Define entries under `.url` in `app/{desktop_uidir}/config`. Keep entry IDs
stable and prefix them with the app name. Validate:

- `title`, `icon`, and `type=iframe|url`;
- `protocol=http|https|""` for port entries;
- `port` and `url`, with stable wizard substitutions when required;
- `allUsers`, `fileTypes`, and `noDisplay`;
- optional `control.accessPerm=editable|readonly|hidden`;
- gateway fields when using the unified gateway.

Device-verified entry contracts:

- `port` must be a JSON **string** (`"5710"`). A numeric JSON port broke
  client-side URL assembly on real devices, and the client silently fell back
  to the gateway path and refused the connection.
- `url` is a request **path** (for example `/` or `/management.html`) that the
  platform combines with `protocol` + `port`. Never put a full link
  (`http://host:port`) in `url`; the client cannot parse it and the entry
  fails.
- `type=url` opens in an external browser tab or web view; `iframe` renders
  inside the fnOS desktop window. Desktop/mobile clients cache entry
  definitions — 在源码修改入口并经新 FPK/App Center 更新后，关闭并重开应用窗口或刷新客户端再验证；这里不允许热改 installed `ui/config`，也不重启 DSH 服务。

Use `allUsers=false` plus an appropriate `control.accessPerm` for
administrator-only entries. Treat the `path` query added by file-open entries
as untrusted and check authorization before access.

## Wizards

Use JSON arrays for `wizard/install`, `upgrade`, `uninstall`, and `config`.
Each step has `stepTitle` and `items`; each input has a stable `field` that
becomes an environment variable.

Supported documented item types are `text`, `password`, `radio`, `checkbox`,
`select`, `switch`, and `tips`. Rules include `required`, `min`, `max`, `len`,
and `pattern`.

- Ask only for values that cannot be derived safely.
- Prefer a `wizard_` prefix and never use the reserved `TRIM_` prefix.
- Preserve published field names across upgrades.
- Use `password` for secrets, never log them, and validate every value again in
  lifecycle code.

## Dependencies and runtimes

Documented runtime app names include:

- `python312` at `/var/apps/python312/target/bin`;
- `nodejs_v22` at `/var/apps/nodejs_v22/target/bin`;
- `java-21-openjdk` at `/var/apps/java-21-openjdk/target/bin`.

Declare the runtime in `install_dep_apps`, then prepend its `bin` directory or
invoke the executable explicitly. Keep application dependencies in the
application area. 离线 Python 依赖须匹配解释器版本/ABI/平台，锁定 wheel 版本与 SHA-256，随包保留许可，初始化使用本地 wheelhouse 和哈希约束；本技能不附带完整 wheelhouse 构建手册。

“依赖已登记”不代表 SDK 可运行。安装前做只读预检：解析 SDK symlink 最终目标及祖先、检查解释器与 ELF/加载器/共享库架构、执行版本查询，并在已准备的代表环境中做 native import。Python 使用 `-I -B` 等关闭用户环境与字节码写入；只读检查不安装包、不修改 SDK、不导入带业务副作用的应用入口。目标 ABI、最低支持 fnOS 和最少一项实际 native import 要有实机证据。

[native_preflight.py](../scripts/native_preflight.py) 输出依赖、身份与权限前提的只读 JSON；先读脚本帮助/实现确认精确参数。新包专用身份或尚待 App Center 安装的依赖可未创建，将该项记录为后续依赖/回调阶段再核验，勿伪造 UID/GID 或 SDK 通过。已登记却缺失的 SDK 由 App Center 正常修复，不在 target 内补链接或 chmod/chown。

Redis, MinIO, and RabbitMQ are application dependencies, not implicit system
services. Namespace databases, keys, buckets, queues, and routing keys; never
ship production credentials.

## Icons

Provide:

- root `ICON.PNG` at 64 x 64;
- root `ICON_256.PNG` at 256 x 256;
- every UI image referenced through `images/icon_{0}.png`, normally 64 and
  256 pixel variants.

Keep images PNG/JPG, sRGB, square, and at most 1024 KB. Preview actual artwork
at 64 pixels; do not accept generated placeholder icons as release assets.

## Build, install, and publish checks

1. Resolve user-owned maintainer/distributor values and decide whether the
   intended output crosses an artifact boundary. Increment `version` first
   when changed packaged bytes will cross that boundary.
2. Validate manifest, JSON, lifecycle shell syntax, UI entry paths, images,
   and target architecture.
   Run `scripts/audit_fnos_project.sh` and manually review findings that
   depend on generated or undocumented behavior.
3. Build with resolved fnpack; never substitute a manually assembled tarball.
4. Inspect the FPK plus nested `app.tgz`; record version, bytes, and SHA-256.
5. 加载已注册 `fnos` 技能并按 [App Center 交接](fnos-app-center-handoff.md) 使用当前 `trim-cli` 与 UI；NAS 上的 FPK 先按实际卷执行 `app install-fpk --remote-path ... --volume-id ... --dry-run --yes`。依赖变更走 UI，不用另一 CLI 绕过检查。
6. Keep sensitive wizard env files out of source control.
7. Test install, entry, start/stop/status, persistence, permissions, failure
   behavior, and every supported architecture/system version.
8. Use a dedicated test NAS. Do not claim device success from local build
   checks.

原生服务最低验收矩阵：

| 流程 | 必须保留的证据 |
| --- | --- |
| 全新安装/首次启动 | 正确版本与任务成功、SDK 实际可执行、初始化完成、专属单元和 PID 身份正确、health 就绪。 |
| 停止后的冷启动 | 支持的 App Center 停服后 MainPID=0/固定端口释放；再次启用后新 PID 身份、health 与控制面 running 一致。 |
| 初始化失败 | 原始失败阶段/退出码/日志、未误报 running、无错误注册或残留本应用进程、旧状态保存。 |
| 失败恢复 | 限定本应用的恢复证据、未热改安装树、数据/配置/revision 摘要与元数据保存、新任务真实成功。 |
| 升级 | incoming 脚本面对旧 target 的矩阵、旧进程停服、新控制器/模板 pin 符合、设置与数据保留。 |
| 网页入口 | `app entry list`/当前用户桌面信息与注册 URL 一致；实际浏览器打开入口、渲染与关键资源成功。 |

证据链同时核对 App Center 任务/版本/`running`、systemd 的专属 Fragment/Type/User/Group/ActiveState、实际 PID 的 UID/GID/可执行文件/argv、health、停止后端口释放及浏览器。`status=start`、版本已登记、PID 存在或静态审计零问题都不是单独的通过条件；幂等启用已健康服务不代替冷启动。未执行的场景标待验证，不借此删除用户数据。

本技能的只读 JSON 检查入口：[native_preflight.py](../scripts/native_preflight.py)、[check_native_runtime.py](../scripts/check_native_runtime.py)、[check_content_pins.py](../scripts/check_content_pins.py)、[validate_skill.py](../scripts/validate_skill.py)。先读各工具精确参数；检查器不自动修复 SDK、摘要、安装权限或运行控制面。
