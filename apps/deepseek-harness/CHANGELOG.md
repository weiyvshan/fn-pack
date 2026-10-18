# Changelog

## Unreleased

## 0.0.18

- 上游基线从 `dsh-v0.1.7-rc.1` 升级到 `dsh-v0.2.1-rc.2`（commit `687f282e`，tree `f127f0f9`），`dsh_version` 记为 `0.2.1-rc.2`；选择该 tag 而非 npm `latest`（`0.2.0-rc.2`），因为反向代理与外网访问相关模块只存在于 0.2.1 线。
- 四个锁定源码补丁在新基线上重做并逐补丁 `git apply --check --whitespace=error-all` 通过、按序应用成功（命中 14 个上游文件）：`0002` 随上游 `runProfilePnpm` 重构改写（引入输出状态持有者、移除 `await using`、拆分迁移与默认依赖读取）；`0004` 随上游 web-app 引入 `publicUrl` 与 `appRootUrl()` 改写，`DSH_WEB_AUTH_TOKEN_FILE` 私有令牌交接语义保持不变；`0008` 只保留数值默认值改写（Gateway 心跳 2000→15000、`generationReadyWarnMs` 3000→10000、`generationReadyTimeoutMs` 15000→45000），断开语义改写已由上游 0.2.1 取代；`0007` 在新基线上原样适用。
- `runtime.lock.json` 更新上游 commit/tree/日期、`pnpm_lock_sha256`（`4637cca3`）、`cli_package_sha256`（`d42efe9f`）与四个补丁摘要；pnpm 从 `11.7.0` 升至 `11.28.5`。
- `dsh-purge` 插件归档是设备侧 profile 依赖，不随 FPK 分发；本次升级未改动该插件，`plugin-locks/dsh-purge.json` 的 `dsh_target` 仍记录其已审计的适配目标 `0.1.5-rc.2`，它与 0.2.1 插件 API 的兼容性未经验证。
- 待验证项：上游 0.2.1 新增应用内目录选择器（`ui-directory-picker-*`）与 `dsh-host-open-in-app` / `dsh-client-ui-open-in-app`，可能与 `app/web/fnos-open-enhancer.js` 的打开行为重叠，需在设备侧对比后再决定是否退役该增强脚本。
- 更正内置 `dsh-maintenance` 技能中过时的环境契约：fnOS 卷序号与应用专用 UID 改为按安装实例分配（G480 实例 `/vol2`、uid 950/gid 945；YDYNAS 实例 `/vol1`、uid 924/gid 919），不再把 `/vol2` 与 uid 950 陈述为固定约定。
- 更正该技能的存放约定章节：改为描述实际投放方式（应用目标 `builtin-skills/dsh-maintenance/`，由启动器经 `DSH_BUNDLED_SKILL_DIR` 暴露，不复制进 `${DSH_HOME}/skills`），删去已失效的"用户级只读目录 555/444"与"不使用 bundled 机制"表述，并明确该目录禁止设备侧改动。
- 同步更新 `scripts/test-package.sh` 与 `scripts/test-package.ps1` 中该技能的哈希锁定。
- 修复 `tests/dsh-launcher.test.sh` 的环境隔离缺陷：在 fnOS 应用环境内运行时，环境自带的 `TRIM_PKGHOME` 会覆盖 launcher 的 `PKG_HOME` 推导，使测试在本机必然失败；现于测试内显式 `unset TRIM_PKGHOME`。

## 0.0.17

- 新增第四个锁定源码补丁：Gateway 默认每 15 秒发送 Ping；Connection 默认在 10 秒报告 generation 未就绪，并在 45 秒终止该等待。显式配置继续覆盖默认值。
- 网关每次上游升级握手限制为 10 秒，握手头部及待升级客户端缓冲限制为 64 KiB；升级后的 WebSocket 字节流保持原样转发，持续请求排空 45 秒时成对关闭两端 socket，EOF 则先在同一期限内写完队列中的尾帧。
- 新增包内 changes-summary 客户端兼容适配：仅精确 `404` 正文进入 60 秒、256 项上限的缺失缓存；网络、HTTP `5xx` 与无效 JSON 保持可重试错误，保留本地化重试按钮、一秒退避与取消代际隔离。
- 构建器在 fnpack 前只读验证编译客户端的旧形态、内存改写后的适配形态及完整脚本语法；构建元数据、嵌套载荷和 Linux/PowerShell 包测试纳入新组件。
- 产物统一命名为 `deepseek-harness_0.0.17_x86.fpk`。

## 0.0.16

- 修复 WebSocket 升级成功后客户端首帧被双重转发的问题：101 握手接管管道（`socket.pipe(upstream)`）之前先移除握手期数据监听（`detachClient()`），握手期缓冲的客户端帧只经缓冲区写入一次。
- 新增"升级后客户端帧只转发一次"回归测试。

## 0.0.15

- 网关缓存的认证 Cookie 失效后不再永久 401：非根 GET 遇 401/403 自动刷新网关会话并重放一次（流已消费的请求按 `request.complete` 直接结束重试），WebSocket 升级在握手段检查上游状态，401/403 时刷新会话重连一次，其余拒绝原样透传给浏览器。
- 令牌交换（`GET /?token=`）新增 10 秒超时、HTTP 状态码校验（仅 200/303 视为成功）与请求中止清理；会话刷新时重读 `web-auth.token`，令牌轮换无需重启网关。
- Session 导出（`/__fnos/export-session`）上游请求注入网关持有会话 Cookie，并在导出路由 401/403 时一次性刷新重试；导出测试夹具改为鉴权后端并断言注入行为。
- `remote.mux` 静态前缀还原的触发条件从 `REMOTE_STREAM_MUX_PATH.slice(1)` 源码标记放宽为任意带引号的网关前缀 mux 路径字面量，压缩/重构后的 bundle 同样命中。
- 新增认证韧性回归：无关 Cookie 保留与多 `dsh-auth-*` 剥离、会话轮换恢复、令牌文件轮换恢复、WebSocket 拒绝重连、交换超时拒绝。

## 0.0.14

- 将官方运行时升级到 `dsh-v0.1.7-rc.1`（commit `46a7f68b0922371ce7144b668b90e377d8e799f4`），锁定新 tree、lockfile、CLI manifest、pnpm `11.7.0` 与 `@deepseek-ai/node-addon-system-linux-x64` `0.1.2`。
- 将 8 个旧源码补丁收敛为 4 个：移除已由上游 standing sandbox 与统一 `RuntimeResolution`/`PluginPackages` 覆盖的补丁，保留 Web 私有认证令牌、附件卷边界和 3072 MiB TypeScript 构建上限。
- 以窄补丁接入上游 `plugin_manager`：fnOS 下所有插件操作使用 profile 私有 `.pnpm-store`，旧 store 绑定在首个变更前执行 `pnpm install --force` 重链，失败时阻止请求的变更并恢复受管文件。
- 网关从已安装 profile 依赖中仅派生审计过的已知路由；现有显式 registry 项继续热读，未知动态命名空间保持管理员确认与显式登记边界。
- 更新 Linux/PowerShell 构建契约、回归测试、内置 `dsh-maintenance` 技能与第三方声明；生命周期钩子继续不迁移用户 profile、设置、Session 或插件数据。

## 0.0.13

- 修复 fnOS 文件管理器把文件名当作路径导航、面包屑最后一级报「文件或文件夹不存在」的问题：宿主 `openFileManager`（minified `TQ`）是目录导航 API，对文件路径会按目录层级展开至不存在的末级。
- 资源管理器（reveal）按类型分流：网关新增只读 `__fnos/stat` 探测端点（权限边界与 export-open 一致），目录打开自身（方案 B），文件或探测失败回退打开所在目录。
- Session 导出与导出后打开（exportThenOpen）统一改为打开 `dsh-exports` 导出目录——导出物恒为文件，原样传给 `openFileManager` 同样触发本 bug。
- 新增回归：目录 reveal 自身、探测失败回退、stat 端点 405/400/200/403 行为；静态契约锁定 `parentOfPath`、`revealOpen`、`statProbeIsDirectory`、`PATH_STAT_PATH`。

## 0.0.12

- 修复 `dsh-better-sidebar` 文件树右键「在应用中打开」在 fnOS 上点击无反应的问题：该菜单经 `POST /sidebar/api/open.external` 到达插件服务端后交给 `xdg-open`，而 fnOS 无桌面环境不存在该命令，spawn 错误被插件吞掉，客户端仍收到 `started:true`，因此在 fnOS 上从未生效。
- fnOS 适配器新增 `installSidebarOpenExternalAdapter`：仅在嵌入宿主下拦截 reveal 动作，可见工作区路径直接转发 fnOS `openFileManager`，不可见路径沿用既有导出后打开链路；`url` 动作（vscode:// 等本机编辑器协议）与独立浏览器页保持透传，不扩大改动面。
- 返回插件 `readEnvelope` 约定的 `{ok:true,value}` / `{ok:false,error}` 信封，失败通过 `bad-request` / `open_failed` 错误码暴露；新增六组回归覆盖可见、私有、透传、无关路由、非法路径与独立页场景。

## 0.0.11

- 修复 OpenInAppAction 仅在点击后才构造 `TrimApp`，错过 fnOS 父页面 Web 桥接初始化时窗并在 5000 ms 后进入错误态的问题。
- 网关在增强器之前以阻塞脚本加载 `@trimjs/web-app`，增强器在页面引导阶段同步选择 Web carrier 并预热 `ready()`；点击仅复用已连接实例，`/vol2/1000/DSH` 与 `/vol2/1000/Note` 等已授权工作区直接交给文件管理器。
- 增加引导期桥接回归，模拟“只有早期构造才能连接宿主”的时序，并确认 `Note` 工作区不会误入常规文件导出端点。
- 将 fnOS 源码构建的 TypeScript V8 老生代上限从 4096 MiB 降至 3072 MiB，降低 8 GiB 设备在构建期间触发全局 OOM 的风险，同时保留实测所需编译余量。
- 新增哈希锁定的上游补丁与回归测试，要求构建脚本保留 3072 MiB 上限并排除旧的 4096 MiB 配置。

## 0.0.10

- 恢复交付文件卡片主按钮和整卡预览的原生右侧 Sidebar 链路；此前 fnOS DOM 增强器在捕获阶段拦截 `在侧边栏打开` 按钮，导致 `sidebarRight.openResource()` 永远收不到点击。
- fnOS 适配器不再扫描或改写 `data-presented-file` 卡片，不再阻止原生事件；Session Header 的 OpenInAppAction、Web carrier 选择、SDK ready 超时和 Session 导出保持不变。
- 增加回归测试与静态契约，要求 Sidebar 点击不被取消、不触发 fnOS SDK/导出请求，并禁止重新引入交付卡片劫持代码。

## 0.0.9

- 修复真机从 0.0.7 升级时，持久化 profile 的 `node_modules` 软链仍指向旧 runtime 中已消失的嵌套依赖，导致 `install_callback` 在 DSH 自愈前将数据目录判为无效并回滚的问题。
- 安装、升级、配置和启动前仅清理目标已经断裂、且规范化目标仍位于当前 `${TRIM_APPDEST}/server` 内的 runtime 派生软链；有效链接保持不变，指向边界外的链接继续拒绝。
- 增加生命周期回归测试，覆盖受控断链清理、有效 runtime 链保留和外部断链拒绝。

## 0.0.8

- 修复 fnOS Web 桌面 iframe 的用户代理包含 `FNAppVer` 时，`@trimjs/web-app` 0.4.2 将 Web 宿主误判为移动端并永久等待 Flutter bridge，导致 `OpenInAppAction` 点击后持续处于 busy 状态的问题。
- 仅在构造 `TrimApp` 期间临时移除 `FNAppVer`，强制选择 Web carrier；为 SDK ready 增加 5 秒上限，桥接异常时返回明确错误并释放控件状态。
- iframe 内固定提供唯一的 `filemanager` 选项，独立浏览器页面返回空目录，并拒绝向 NAS Host 转发残留的桌面编辑器选择。
- 修复作为 `app.tgz` 固有 Web 资源交付，不依赖升级迁移或现场补丁；全新安装与从旧版升级使用同一份适配器和启动路径。
- Linux 构建与校验链统一使用原生 Bash/Node.js/Python 入口；新增 `source-checkout.test.sh` 覆盖源码解析器回归，Linux 包测试不再要求、探测或跳过 PowerShell 脚本。

## 0.0.6

- 修复 fnOS 升级期间再次执行 `install_callback` 时，旧 `wizard_proxy_*` 和 `wizard_deepseek_api_key` 覆盖应用中心当前配置的问题。
- 使用持久化初始化标记和回调开始时的 `.dsh` 存在性区分“尚未应用初装值”和“用户已配置或主动清除”，升级及保留数据重装不再复活旧代理或 API Key。

## 0.0.5

- 以 G480 当前用户技能内容为基准，将 `dsh-maintenance` 作为只读内置技能纳入源码，并通过 DSH 的 bundled skill 根目录自动发现。
- 增加来自 G480 当前用户目录的 `skill-creator` fnOS/Linux 子集，保留 `SKILL.md`、参考文档和 Bash 辅助脚本，不将 `.ps1` 脚本纳入 FPK 源码。
- 同步真机 Bash 修复：非法资源类型立即失败且不创建垃圾目录，Markdown 模板不执行反引号，front matter 键名正确 trim，YAML 反斜杠与可选值中的分号保持完整。
- App Center 启动与设备端 `dsh` 命令统一导出 `${TRIM_APPDEST}/builtin-skills`；任一内置技能主文件缺失时明确拒绝启动。
- 将两项技能的文件清单、原文哈希、构建来源记录和最终 FPK 必备项纳入验证；不复制、覆盖、删除或修改 `${DSH_HOME}/skills` 用户层及其 ACL。

## 0.0.4

- 内置 `gateway-route-injection` 技能，用于处理插件动态 HTTP 路由未被统一网关自动发现的问题。

## 0.0.3

- 修复图片附件首次落盘时逐级同步到文件系统根目录，因 fnOS 应用账户无权打开外层卷目录而失败的问题。
- DSH_HOME 的直接父目录完成同步后，允许在不可打开的外层卷边界停止；若直接父目录本身不可同步，仍按附件写入失败拒绝请求。
- 将附件暂存目录初始化错误统一映射为 `ATTACHMENT_WRITE_FAILED`，避免再显示误导性的 `session/agent-busy`。

## 0.0.2

- 修复安装阶段因创建 `/home/deepseek-harness` 系统软链失败而回滚的问题。
- 运行时继续使用 `TRIM_PKGHOME` 作为 `HOME` 和 `DSH_HOME`，不再修改系统 `/home`。

## 0.0.1

- 将应用标识重置为 `deepseek-harness`。
- 移除升级期间的运行时、profile、设置和旧数据迁移逻辑；升级钩子仅负责停止进程并校验新文件。

## 0.1.26

- 修复 G480 已确认的升级失败：旧 `0.1.22` `upgrade_init` 会把刚应用的新 `target/server` 移入 `upgrade-runtime-backup`，导致后续启动报运行时缺失。
- 运行时升级快照由移动改为非破坏性复制，避免升级生命周期主动制造缺失的运行时目录。
- `upgrade_callback` 可识别并重新物化旧钩子暂存的新运行时，同时保留快照直到启动稳定性检查完成。

## 0.1.25

- 修复旧 `dsh-home` 迁移失败：允许 profile 中指向当前应用 `server` 运行时的受控符号链接，同时继续拒绝真正越界的链接。
- 迁移、快照、合并和恢复统一使用同一个规范化的应用运行时边界。

## 0.1.24

- Raise the installable package revision after the previous `0.1.23` artifact
  was not accepted by fnOS during upgrade.
- Keep `/home/deepseekharness` deletion strictly limited to the exact link
  pointing at the current apphome. If an ordinary object or a link to another
  target is present, uninstall records a warning and completes without
  deleting it, so a stale compatibility entry cannot block package removal or
  the next upgrade attempt.

## 0.1.23

- Normalize `TRIM_PKGHOME` through `realpath` before validating or removing
  `/home/deepseekharness`. Equivalent fnOS path spellings such as a trailing
  slash remain compatible with the exact-link safety rule, while ordinary
  directories and links to another target are still rejected.
- Keep `${TRIM_PKGHOME}` as `HOME` and the visible app root, but remove the
  package-level additional writable sandbox root. Default `workspace-write`
  therefore cannot modify `${TRIM_PKGHOME}/.dsh`; operations that need to
  change `DSH_HOME` must use an explicitly authorized higher-risk mode.
- Remove the fnOS-specific additional-writable-roots upstream patch and keep
  the sandbox's original workspace and temporary-directory boundary.

- Use `${TRIM_PKGHOME}` (`/vol2/@apphome/deepseekharness`) as the application
  Unix home and create only the exact compatibility link
  `/home/deepseekharness -> ${TRIM_PKGHOME}` during install and upgrade.
- Use `${TRIM_PKGHOME}/.dsh` as the single active `DSH_HOME` for credentials,
  profiles, plugin state, web-auth tokens, and runtime state. First installs
  initialize it directly; upgrades migrate `${TRIM_PKGVAR}/dsh-home` into it,
  preserve the old directory as an inactive backup, and keep apphome visible.
- Keep the existing first-`TRIM_DATA_SHARE_PATHS` workspace selection. The
  gateway exposes `${TRIM_PKGHOME}` as a visible root, so the nested `.dsh`
  data is intentionally visible rather than treated as private state.
- Keep Harness-managed shell persistence below `${TRIM_PKGVAR}/shell` and
  export `HISTFILE` plus XDG state/cache/data roots there. Upstream terminal
  children continue to receive the reserved `DSH_SHELL=1` marker.

## 0.1.21

- Adapt the Session Header `下载 Session 日志` action and `/export` command in
  the embedded fnOS Web desktop: the gateway obtains the authenticated DSH ZIP,
  validates and stores it under `dsh-exports`, and the Web adapter opens it in
  the fnOS file manager instead of starting a browser download.
- Include fnOS user-authorized roots from `TRIM_DATA_ACCESSIBLE_PATHS` in the
  gateway's browser-visible path set, alongside package-owned
  `TRIM_DATA_SHARE_PATHS`. This keeps restored sessions under an authorized
  user workspace on the direct `openFile` / `openFileManager` route instead of
  misrouting a directory to the regular-file export endpoint and receiving
  HTTP 400 after an application restart.

## 0.1.20

- Harden the lifecycle health check: the `status` backend probe now retries
  up to three times (1 s timeout per attempt) before reporting a partial
  state, so a transient load spike no longer makes the platform record a
  crash for a healthy, busy service.

## 0.1.19

- Replace the presented-file card's stock open action inside the fnOS Web
  desktop iframe with the fnOS `openFile` page route, preserving the sidebar
  preview and exporting paths outside authorized shares through the existing
  collision-safe gateway endpoint.
- Keep standalone browser pages on the upstream open behavior and add a DOM
  regression test for the current `open button + menu anchor` card structure.
- Add a gateway-owned iframe adapter for DSH's open-in-app `filemanager`
  choice: expose it even when the Linux Host has no local desktop and route it
  to fnOS `openFileManager`, while leaving editor choices and standalone Web
  access on the upstream behavior.

## 0.1.18

- Rebuild the pinned official runtime from upstream `dsh-v0.1.5-rc.2`
  (`fb2c4b9e698e30edb738bca4cf0618587db7d203`) with all six local source
  patches replayed and re-verified against the new tree, including the
  regenerated `pnpm-lock.yaml` importer section for the profile-scoped
  `dsh-tool-plugin` package.
- Adapt the source build chain to the upstream `native/system` package rename:
  the runtime now overlays the official
  `@deepseek-ai/node-addon-system-linux-x64` `0.1.2` binaries (static Landlock
  launcher plus glibc/musl flock Node-API addons) and the deployed runtime is
  verified against them.
- Route the new root-level `/open-in-app/` surfaces through the fnOS gateway
  prefix rewrites so the Open-In button works behind the application path.
- Add an "open in fnOS" action to the presented-file cards: a vendored
  `@trimjs/web-app` `0.4.2` SDK bundle (hash-locked under `app/web/`) and an
  injected enhancement script call the fnOS `openFile` page routing for paths
  inside the authorized data shares, while a gateway-local
  `POST /__fnos/export-open` endpoint copies other reachable workspace files
  into `${DSH_WORKSPACE}/dsh-exports/` (realpath containment against the data
  shares and `DSH_HOME`, sanitized collision-safe names) before opening them;
  the manifest now declares `micro_app = true` for the page-routing bridge.
- Add the profile plugin compatibility gate: upgrades and startup quarantine
  every third-party web-profile plugin that does not positively declare
  compatibility with the target official runtime version (explicit release
  map, engine range, or covering `@deepseek-ai/dsh-*` peer ranges), keeping an
  auditable, hand-recoverable backup under `dsh-home/plugin-quarantine/`.
- Record the `dsh-purge` adaptation as targeting `0.1.5-rc.2`; the vendored
  cordis plugin API is unchanged between the two upstream releases.

## 0.1.17

- Generate deterministic, device-readable `build-info.json` metadata with the
  independent fnOS package version, non-alpha upstream DSH source identity,
  source marker identity, and hashes for package-owned runtime components.
- Reject a build when the source-only `server/package.json` marker survives
  runtime generation, when fnpack emits into a non-empty or ambiguous output
  directory, or when final archived components differ from the staged hashes.
- Validate normalized final manifest fields and move the versioned FPK into
  `build/` only after its size and SHA-256 have been captured and preserved.

## 0.1.16

- Repair the known `dsh-mobile-ui` `0.1.0-rc.1` client registration ID at the
  administrator-only fnOS gateway, matching the package's `dsh-mobile-ui`
  loader row instead of its incorrect scoped handoff.
- Require the known viewport, bottom-navigation, and root-attribute markers
  before rewriting, support direct and combined client bundles, and leave
  unknown or already-correct module shapes unchanged.
- Disable conditional revalidation for affected client requests so a cached
  unadapted bundle cannot retain the duplicate-registration boot failure,
  without changing third-party files or the non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.15

- Extend the application-scoped proxy environment with npm/pnpm aliases while
  retaining standard uppercase and lowercase HTTP(S) variables plus loopback
  exclusions for Node fetch, Corepack, curl, and Git HTTPS consumers.
- Normalize standard proxy variables in the packaged pnpm launcher and
  explicitly forward the complete proxy contract to approval-gated official
  plugin install and remove subprocesses.
- Keep the no-proxy path free of synthesized variables or persistent
  `.npmrc`, `.env`, and shell-profile changes while retaining the non-alpha
  official `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.14

- Reject service startup before persistent-state writes when the current UID
  does not match the fnOS-provided package `TRIM_UID`, preventing root or SSH
  launches from leaving inaccessible PID, port, log, or authentication files.
- Keep administrative `stop` cleanup available and direct operators to enable
  the application through fnOS App Center.
- Add a lifecycle regression proving that a wrong-UID start fails without
  creating state while retaining the non-alpha official `@deepseek-ai/dsh`
  `0.1.2-rc.1` runtime.
- Adapt recognized `dsh-better-sidebar` client and registry bundles at the
  fnOS gateway so successful `agent-terminals` and `agent-opens` connections
  reset their failure counters, send a 25-second heartbeat, and clear the
  heartbeat timer on close or unmount.
- Disable conditional revalidation for those two known bundle routes and
  leave unknown or partially matching plugin shapes unchanged.

## 0.1.13

- Restrict HTML base and runtime-adapter injection to responses whose media
  type is `text/html` or `application/xhtml+xml`, preventing JavaScript chunks
  containing embedded HTML strings from being corrupted by the fnOS gateway.
- Continue rewriting approved same-origin routes inside JavaScript responses,
  including the `dsh-better-sidebar` editor chunk under `/sidebar/`.
- Add a syntax regression for JavaScript containing an HTML document literal
  while retaining the non-alpha official `@deepseek-ai/dsh` `0.1.2-rc.1`
  runtime.

## 0.1.12

- Resolve dynamic Agent preset rows under the same fnOS module policy used by
  the root Loader and client module catalog, preventing persistent profile
  dependencies from shadowing the FPK's compatible official runtime.
- Keep non-DeepSeek preset packages on the active profile resolution base so
  retained third-party plugins continue to load normally.
- Add a mount regression covering both resolution paths while retaining the
  non-alpha official `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.11

- Rewrite same-origin `URL` objects used by the official client RPC transport,
  so `/api/...` requests remain under the fnOS application gateway prefix.
- Apply the runtime adapter to built-in routes as well as approved dynamic
  plugin routes, including fetch, XHR, WebSocket, and EventSource callers.
- Preserve the official `"/api"` channel identifier instead of treating every
  exact string occurrence as a browser URL.
- Keep the independent fnOS release series and the non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.10

- Recognize the verified `@linxin666/dsh-web-all` `0.3.16` aggregate client as
  a container for its embedded remote Web UI, so the administrator-only fnOS
  gateway no longer exposes a desktop pairing flow that a headless NAS cannot
  complete.
- Adapt each recognized standalone or aggregate module independently while
  leaving unknown or ambiguous module shapes unchanged.
- Disable conditional revalidation for direct and combined settings, plugin
  manager, remote Web UI, and Web aggregate client resources.
- Keep the independent fnOS release series and the non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.9

- Allow the installed `dsh-at-file` `0.7.0` bundle to remain enabled alongside
  `@linxin666/dsh-web-all` `0.3.16`; that release explicitly supports the
  Harness 0.1.2 client package layout.
- Continue disabling older, missing, malformed, or otherwise unverified
  `dsh-at-file` package metadata, as well as the incompatible legacy
  `@linxin666/dsh-web-ui-all` aggregate.
- Keep the independent fnOS release series and the non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.8

- Recognize the current parameterized loopback fence used by the retained
  `@linxin666/dsh-remote-web-ui` client, restoring workspace, model, and session
  APIs inside the administrator-only fnOS gateway.
- Preserve compatibility with the earlier explicit page-hostname fence while
  refusing to rewrite unknown or ambiguous client shapes.
- Keep the independent fnOS release series and the non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.7

- Resolve official `@deepseek-ai/*` client bundle metadata from the FPK's
  locked runtime, matching the server-side Loader policy introduced in 0.1.6.
- Prevent retained profile dependencies from serving an older
  `dsh-client-modules/client.js` bootstrap bundle while continuing to serve
  third-party client bundles from the active profile.
- Add v1/v2 Loader regression coverage and retain the non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.6

- Resolve every `@deepseek-ai/*` Loader entry from the FPK's locked runtime,
  preventing retained third-party profile dependencies from replacing the
  compatible official module set during startup.
- Continue resolving non-DeepSeek bare modules from the active profile, so
  supported third-party plugins remain usable alongside the pinned runtime.
- Add a conflicting-module regression test while retaining the non-alpha
  official `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.5

- Stop passing the profile-level `--no-open` option during service startup;
  the managed private-token handoff already suppresses native browser opening,
  while retained third-party Web profiles may reject that option and exit.
- Preserve the `0.1.4` profile, preset, rollback, and actionable-error repairs,
  with the upstream runtime still locked to non-alpha `0.1.2-rc.1`.

## 0.1.4

- Migrate the obsolete `agent-presets.default: code` value to `standard`
  during upgrade when no user-authored `code` preset exists, restoring new
  session creation after the upstream preset roster changed.
- Back up and restore `settings.yaml` in the same transaction as the packaged
  runtime and Web profile so a failed start also rolls back the preset change.
- Recheck known-incompatible Web bundles on every start, repairing the restart
  failure caused when `dsh-at-file` is re-enabled after upgrade.
- Preserve the first actionable startup error when no upgrade backup exists
  instead of replacing it with an unrelated recovery warning.
- Keep the package release series independent while retaining the non-alpha
  official `@deepseek-ai/dsh` `0.1.2-rc.1` runtime.

## 0.1.3

- Fix the fnOS unified gateway so the official settings client can load and
  persist the provider catalog outside a browser-localhost deployment.
- Bypass stale conditional responses only for the recognized official settings
  bundles and keep unknown bundle shapes unchanged.
- Separate the fnOS package version from the retained non-alpha official
  `@deepseek-ai/dsh` `0.1.2-rc.1` runtime version.

## 0.1.2-rc.8.11

- Restore the fnOS unified-gateway UI after official DSH `0.1.2-rc.1` made a
  signed browser session mandatory for index, RPC, and WebSocket requests.
- Publish the per-process launch token only through an atomic private
  mode-`0600` file, suppress token-bearing URL logs, and disable native browser
  opening in the NAS service.
- Exchange the private token only after the fnOS gateway identifies an
  administrator; forward the clean redirect and path-scoped Cookie, retry an
  expired or invalid Cookie, and discard any browser-supplied root token.
- Keep the bundled official `@deepseek-ai/dsh` runtime at the non-alpha
  `0.1.2-rc.1` release commit.

## 0.1.2-rc.8.10

- Disable retained `dsh-at-file` and `@linxin666/dsh-web-ui-all` bundles during
  upgrade because their current releases import APIs removed by official DSH
  `0.1.2-rc.1`; preserve dependencies, installed modules, settings, and data.
- Back up and restore the profile manifest in the same transaction as the
  packaged runtime so a failed start restores both runtime and bundle state.
- Require the backend process and HTTP endpoint to remain healthy for 15
  seconds before publishing the gateway and committing upgrade backups.
- Report startup failure accurately when no valid pending runtime backup exists
  instead of claiming that an old runtime was restored.
- Keep the bundled official `@deepseek-ai/dsh` runtime at the non-alpha
  `0.1.2-rc.1` release commit.

## 0.1.2-rc.8.9

- Work around the G480 fnOS App Center comparison that rejected package
  `0.1.2-rc.1.0` as not newer than installed `0.1.0-rc.8.x` releases.
- Keep the bundled official `@deepseek-ai/dsh` runtime at non-alpha
  `0.1.2-rc.1`; only the fnOS package identity changes.
- Build the release FPK with the repository's Linux `fnpack` inside WSL and
  preserve executable modes from Linux runtime archives.

## 0.1.2-rc.1.0

- 升级官方 `@deepseek-ai/dsh` 运行时到 `0.1.2-rc.1`，固定 release commit `a66e4702047846cdaa10c66c9d3df3951f5ea70d`；明确排除后续 alpha 标签。
- 刷新上游源码锁、`pnpm-lock.yaml` 与 CLI manifest 哈希，并重放三段 fnOS 补丁。
- 保留统一网关、profile-local pnpm store、升级运行时备份、启动失败自动恢复、以及第三方插件由管理员自行保留或移除的行为。

## 0.1.0-rc.8.8

- 在 fnOS 统一网关响应层精确识别已保留的 `dsh-remote-web-ui` 浏览器模块，禁用其不适用于管理员 Web 部署的配对心跳和全局远程请求通道，不修改插件文件或 Host 路由门禁。
- 对可能经过正文适配的 GET 请求禁用上游条件缓存；正文实际变化后移除验证与过期响应头并设置 `Cache-Control: no-store`，避免浏览器继续执行旧脚本。
- 升级前将旧官方 `server` 运行时暂存到应用私有数据目录，新版本通过健康检查后再清理；启动失败时自动恢复旧运行时，profile 插件数据保持不变。
- 修复缺少 `readelf`/`xxd` 环境下的 ELF 头读取回退，保持上游源码提交、补丁及 `runtime.lock.json` 不变。

## 0.1.0-rc.8.7

- Adapt the exact installed `dsh-remote-web-ui` browser module at the fnOS
  administrator gateway so it does not start pairing heartbeats or replace
  global request transports with its `/remote` channel.
- Require the known module ID, effect labels, heartbeat route, and code shape
  before rewriting; leave unknown bundles and unrelated loopback semantics
  unchanged.
- Keep existing profile plugins and Host routes intact while fresh installs
  remain free of third-party Web UI packages.

## 0.1.0-rc.8.6

- Keep a pending backup of the official `server` runtime throughout an upgrade.
- Commit the new runtime only after a healthy service start; restore the old
  runtime automatically when the new package cannot start.
- Preserve the existing third-party Web UI profile and keep fresh installs
  free of third-party Web UI packages.

## 0.1.0-rc.8.5

- Print an explicit post-upgrade notice through the fnOS lifecycle callback:
  existing third-party Web UI plugins are retained for administrator choice,
  while fresh installations still contain no third-party Web UI plugin
  packages.

## 0.1.0-rc.8.4

- Rebuild only the immutable official `server` runtime tree before fnOS
  upgrades so stale rc.7 nested packages cannot be merged with the rc.8
  runtime and prevent startup.
- Preserve the persistent DSH profile directory, including installed
  third-party Web UI plugins, lockfiles, profile-local stores, credentials,
  and workspace data. The upgrade notice does not remove those plugins; an
  administrator may remove them from the plugin manager after the update.

## 0.1.0-rc.8.3

- Adapt the bundled `dsh-plugin-manager` Web client through the fnOS gateway so an authenticated administrator can use the plugin settings page from a Web browser without a browser-localhost requirement.
- Preserve the gateway administrator check, loopback Host semantics, and all upstream DSH sources and patches.
- Ship no third-party Web UI plugin packages for fresh installations; preserve
  pre-existing profile plugins on upgrade for administrators to retain or remove.

## 0.1.0-rc.8.2

- Resolve packaged DSH bare modules from the active profile so `@linxin666/dsh-web-ui-all@0.2.4` and its child plugins load from the profile-local module tree.

## 0.1.0-rc.8.1

- Pass the installed DSH package as the bare-plugin resolution base so profile-local legacy `@deepseek-ai/*` dependencies cannot shadow the bundled rc.8 runtime.

## 0.1.0-rc.8.0

- Upgrade the bundled official `@deepseek-ai/dsh` runtime to `0.1.0-rc.8` at release commit `141eb6fef83422698aef7a981029e843e8161534`.
- Refresh the source lock and generated tool catalog so `@linxin666/dsh-web-ui-all@0.2.4` receives the rc.8 session-history attachment schema, including the required `maxImageDimension` field.

## 0.1.0-rc.7.14

- Generate a fixed internal same-origin marker only after the fnOS gateway has verified an administrator request, so `dsh-task-board` accepts its loopback-proxied state, action, and event requests without trusting browser-supplied provenance headers.

## 0.1.0-rc.7.13

- Remove source maps, TypeScript sources and declarations, tests, documentation, and native build inputs from the verified production dependency tree.
- Reduce the final dependency tree's file count and logical size so App Center performs less extraction and replacement work on small-file-sensitive volumes.

## 0.1.0-rc.7.12

- Migrate profiles that accidentally loaded `dsh-better-sidebar` both directly and through `@linxin666/dsh-web-ui-all`, preventing the duplicate `/sidebar/api` route crash.
- Wait for the DSH HTTP endpoint before publishing the gateway socket, and stop the gateway when its backend PID exits so failed starts do not leave an orphan proxy.

## 0.1.0-rc.7.11

- Merge an audited pnpm policy before profile mutations: allow only the required native build scripts, keep the official `@deepseek-ai/*` release-age exception, reuse bundled `node-pty@1.2.0-beta.15`, and preserve unknown workspace settings.
- Replace the incompatible pnpm `--store-dir` option with `pnpm_config_store_dir`, expose Node.js 24 to lifecycle hooks through `PATH`, and unify manual plus model-facing plugin changes on `<profile>/.pnpm-store`.
- Force-relink module trees still tied to the legacy application-global store before running a requested mutation; stop on migration failure and include module-store validity in recovery reporting.
- Install a supported private `bin/dsh` launcher with mode `0700`, controlled fnOS paths, and the package-managed plugin policy on every install and upgrade.
- Increase the default `dsh_plugin` deadline from 5 to 15 minutes while retaining explicit overrides, cancellation, process-tree termination, output bounds, and rollback.
- Document that the root `dsh-browser` package has no `dsh.bundle` and depends on desktop Chrome/macOS commands, so it is not supported by standard `dsh plugin`; upgrades do not remove an existing mistaken dependency.

## 0.1.0-rc.7.10

- Upgrade the bundled official `@deepseek-ai/dsh` runtime from `0.1.0-rc.5` to `0.1.0-rc.7` at release commit `99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`.
- Adapt the plugin profile runtime link and Linux x64 PTY validation to upstream `node-pty@1.2.0-beta.15` prebuild layout.
- Keep the ordered fnOS source patches, pnpm runtime, Landlock launcher, gateway proxy, and plugin profile security boundaries unchanged; refresh all provenance and source hashes.

## 0.1.0-rc.7.9

- Export a controlled interactive shell to DSH, preferring executable `/bin/bash` and falling back to `/bin/sh`, so plugin terminals do not inherit the fnOS package account's non-login shell.
- Fail startup with an actionable error when neither supported shell is executable, without changing the package account or `/etc/passwd`.

## 0.1.0-rc.7.8

- Add profile-scoped gateway compatibility registration for installed DSH plugins.
- Known plugin namespaces are migrated automatically; unknown safe namespaces require a one-time administrator approval and roll back together with failed plugin mutations.
- Add an approval-gated `dsh_plugin gateway` fallback for dynamic paths that bundle scanning cannot discover, without requiring another FPK release.
- Hot-read the compatibility registry and keep response rewriting plus runtime fetch/XHR/WebSocket/EventSource adaptation limited to registered first-level namespaces and same-origin URLs.

## 0.1.0-rc.7.7

- Rewrite the `dsh-better-sidebar` `/sidebar/*` client route family through the fnOS unified gateway prefix so Explorer, lazy chunks, media and HTML previews, and terminal WebSockets reach the mounted plugin.
- Keep the compatibility rewrite limited to the plugin namespace while preserving prefix stripping, administrator authorization, and unrelated absolute URLs.

## 0.1.0-rc.7.6

- Reuse the bundled, validated `node-pty@1.1.0` package for profile plugin installs through a guarded symbolic link and a structured `pnpm-workspace.yaml` override, avoiding a target-side C++ build.
- Reject missing, mismatched, or redirected native runtime packages and preserve profile rollback, cancellation, timeout, and `recoveryRequired` behavior when initialization or installation fails.

## 0.1.0-rc.7.5

- Rebuild the production runtime from the clean, detached upstream submodule at the locked commit while preserving both ordered, hash-locked source patches.
- Publish the rebuilt payload under a new package version because its generated runtime differs from rc.7.4; keep the fnOS integration contract and existing security boundaries unchanged.

## 0.1.0-rc.7.4

- Increase the default `dsh_plugin` install/remove operation deadline from 120 seconds to 5 minutes so slow downloads and native builds such as `node-pty` can complete.
- Preserve explicit `timeoutMs` overrides and the existing cancellation, timeout recovery, approval, sandbox, and mutation-serialization behavior.

## 0.1.0-rc.7.3

- Accept empty-string placeholders for unused `dsh_plugin` operands so caller surfaces that materialize every declared string field can invoke `list`, `install`, and `remove` without weakening operation-specific validation.
- Keep non-empty conflicting operands rejected before approval or process creation, and add generated-schema plus strict caller-shape regression coverage for all three operations.

## 0.1.0-rc.7.2

- Add a structured `dsh_plugin` tool on the fixed official source commit: `list` is read-only, while every `install` and `remove` requires a fresh one-shot Harness approval.
- Restrict Agent installation sources to npm specs, pinned GitHub shorthand, and credential-free HTTPS tarballs; reject local paths, option injection, invalid profiles, traversal, and symlinks before spawning.
- Run the current DSH CLI as argv through a dedicated profile-scoped sandbox, with the target profile as the only persistent writable root and `.pnpm-store` kept inside that profile.
- Serialize mutations, bound output, support cancellation and timeout, restore profile state after failures, and report `recoveryRequired` whenever complete recovery cannot be proven.
- Upgrade the runtime lock to an ordered, per-patch hash list and verify both source patches, the plugin tests, and real Linux Landlock confinement during the source build.

## 0.1.0-rc.7.1

- Apply a hash-locked patch to the fixed official Harness commit so `tool-bash` treats a projected mode equal to the standing sandbox policy as redundant call metadata, without requiring a justification or approval.
- Preserve the shared strict-widening and approval path for genuinely broader modes, while continuing to reject narrower and malformed requests.
- Run the patched upstream `tool-bash` test target during the Linux source build and retain the exact patch in the final `app.tgz` for provenance.

## 0.1.0-rc.7.0

- Bundle the hash-locked official linux-x64 `landlock-run` launcher omitted by the Git-source workspace materialization path.
- Verify package identity, archive integrity, ELF architecture, official executable mode, byte identity, and a functional Landlock probe before producing the FPK.
- Require the final `app.tgz` to contain the byte-identical launcher, then restore its executable mode during install and upgrade before accepting service startup.
- Record that G480's `appcenter-cli install-fpk` validates an already installed package but does not issue the update RPC; the real upgrade used the authenticated App Center update workflow.

## 0.1.0-rc.6.9

- Stop legacy DSH and gateway processes during upgrade only after verifying the application UID and exact `TRIM_APPDEST` command path.
- Unblock App Center upgrades from releases that left an untracked DSH process after their PID files were replaced.

## 0.1.0-rc.6.8

- Remove the runtime dependency on the community fnOS FPK and build directly from the hash-locked `deepseek-ai/deepseek-harness` Git commit.
- Build the official pnpm workspace in Debian WSL for Linux x86-64, generate the complete required workspace peer closure, and deploy an npm-style hoisted runtime without symbolic links.
- Pin the upstream Git commit, Git tree, source lockfile, CLI manifest, build package manager, and native target in `runtime.lock.json`.
- Update the application-private package manager to the upstream-required pnpm 11.7.0 while keeping the application root free of a license-acceptance file.

## 0.1.0-rc.6.7

- Bundle hash-locked pnpm 10.33.0 as an application-private runtime prerequisite for `dsh plugin`.
- Generate a package-owned launcher in persistent runtime state, expose it only through the DSH child process `PATH`, and keep its store below `TRIM_PKGVAR`.
- Preserve profile plugins in `DSH_HOME` across upgrades without installing pnpm into the NAS-global Node runtime.
- Validate pnpm identity, integrity, target pruning, launcher behavior, and final FPK contents during the build.

## 0.1.0-rc.6.6

- Enable Node's `--use-env-proxy` switch only for the DSH process when a valid application proxy is configured.
- Inject uppercase and lowercase HTTP(S) proxy variables plus `NO_PROXY`/`no_proxy` loopback exclusions only into DSH, without affecting the port selector or unified gateway proxy.
- Fail startup with an actionable error when the configured Node runtime does not support `--use-env-proxy`.
- Preserve the original DSH launch command when no application proxy is configured.

## 0.1.0-rc.6.5

- Remove the generated `cordis.patch.yml` webserver override that caused DSH to bind the selected loopback port twice.
- Keep the dynamically selected port as a single source of truth through the DSH `--port` command-line option.
- Remove only the exact legacy profile generated by 0.1.0-rc.6.3/6.4 during install or upgrade, while preserving customized profiles.
- Add regression checks for the single-port-source lifecycle contract and legacy-profile migration.

## 0.1.0-rc.6.4

- Remove the fixed manifest service port and fnOS port preflight from the gateway-only application.
- Select an available loopback backend port at startup without exposing a LAN listener.
- Replace the 120-second synchronous health wait with bounded process/socket readiness checks.
- Clean PID-verified partial processes when startup is interrupted or an older package is upgraded.

## 0.1.0-rc.6.3

- Package DeepSeek Harness 0.1.0-rc.6 with a hash-locked fnOS x86 runtime.
- Bind the DSH service to loopback and expose it only through the fnOS unified gateway.
- Require administrator identity for HTTP and WebSocket gateway requests.
- Add persistent workspace, optional API-key/proxy configuration, and safe lifecycle supervision.
- Add reproducible staging, static checks, runtime architecture checks, and final FPK inspection.
- Remove target-incompatible Darwin/Windows `node-pty` prebuilds, Windows ConPTY helpers, and debug symbols during staging.
