# Magpie

Magpie 的 fnOS 原生打包工程，使用官方 CLI 提供网页管理界面和 OpenAI 兼容网关。不使用 Docker，无需额外安装 Node、Python、Go 或 Bun；启停脚本使用 fnOS 自带的 `jq` 等系统工具。内置 agent-purge 人设插件与锁定的 Bun 运行时；用户另装的其他插件仍可能需要联网下载依赖。

## 版本与入口

- 飞牛包：`0.1.3042-1`，上游 CLI：`0.1.3042`。
- 平台：`x86`，Magpie 采用 Linux amd64 静态二进制；随包 Bun 使用 glibc x64 baseline 构建，需要 CPU 支持 SSE4.2。最低 fnOS 声明为 `1.2.0800`。
- 管理界面：`http://<NAS地址>:3430`，使用安装向导设置的管理密钥登录。
- 网关默认地址：`http://127.0.0.1:3425`。网关端口可在网页设置中修改，启停和状态检查会跟随保存的端口。

版本与程序来源见 [manifest](manifest) 和 [binary.lock.json](binary.lock.json)，打包变化见 [CHANGELOG](CHANGELOG.md)。上游程序按 MIT 许可分发，文本随包保存在 [LICENSE](LICENSE)。

本版在官方 CLI `0.1.3042` 基础上预装人设插件；上游发布记录见 [magpie-releases](https://github.com/yetone/magpie-releases/releases)。

## 安装与升级

通过 fnOS 应用中心手动安装 FPK。配置、账号凭据、管理密钥和日志保存在应用私有目录，升级保留这些数据。升级前备份应用数据和管理密钥，不通过清空数据解决升级问题。

`0.1.1275-3` 修复旧包装层关闭账号发现的问题：旧版可能已经保存了插件登录凭据，但账号始终没有出现在列表中。本版移除强制关闭账号发现的启动环境和初始化设置，并对旧设置做一次恢复；迁移成功后写入标记，之后尊重用户在网页中的选择，不会每次启动都重新打开。

升级后可在“设置 → 隐私”检查订阅账号开关，再查看插件账号列表。已有凭据会沿用，无需为这次修复重新登录。程序自更新和统计上报仍保持关闭，后续更新通过应用中心安装新 FPK。上游文档说明隐私掩码默认关闭；需要时请在“设置 → 隐私”中检查并开启，旧配置升级后的具体状态需以实际设置为准。

日志目录使用 `0700`，日志、管理密钥和恢复链接文件使用 `0600`。不要把这些文件或含密钥的访问链接提交到仓库，也不要直接修改应用中心的安装目录。

## 内置人设插件

随包插件来自 [agent-purge v0.2.19](https://github.com/ZiChuanLan/agent-purge/tree/09ce906fc9aeee287c9d4891dd0b96bf2db12fb6/magpie-plugin)，插件自身版本仍为 `0.1.0`。这是 FPK 预装的本地插件，不是修改 Magpie 上游内建功能。Bun `1.4.2` Linux x64 baseline 一并分发，通过官方 `MAGPIE_BUN` 指向包内二进制；来源、大小与摘要见 [plugin.lock.json](plugin.lock.json)。

首次启动会注册“人设 / Persona”插件页，默认不改写请求。在页面导入 Markdown 人设，选择 `append`、`replace` 或 `strict` 模式后生效；选择 `off` 停止注入。`strict` 会替换原有 system 文本，包括其中的工具说明，使用前请确认影响。插件不包含本机已有的私人人设或 agent-purge 全套 CLI。

插件选项和导入人设由 Magpie 保存在应用私有 `var/xdg/config/magpie/plugins.json`。可选的 agent-purge 文件状态隔离在 `var/agent-purge`；不要从构建机复制个人状态。升级保留用户选项和停用状态，注册完成后删除插件也不会在每次启动时强制装回。其他路径的同名插件不会被覆盖或重复注册。内置代码随 FPK 更新，用户数据不写入只读插件目录。

## 构建

在 x86_64 Linux 上构建，需要 Bash、Python 3、GNU tar/coreutils，以及隔离回归使用的 `unshare`、`ip`、`ss`、`curl`、`jq` 等工具。构建机须允许创建原生用户和网络命名空间；这不代表应用运行时依赖 Python 或容器。

在仓库根目录执行：

```bash
(
  set -e
  for name in "${!TRIM_@}"; do unset "$name"; done
  export TMPDIR="$(pwd -P)/.tmp"
  mkdir -p "$TMPDIR"
  bash apps/magpie/scripts/build-fpk.sh
)
```

构建脚本会自动准备锁定的官方 CLI，校验大小、SHA-256 和 ELF 架构，再暂存工程、执行隔离回归与审计。SDK 打包后只规范外层 `app.tgz` 权限，不改内层内容和安装清单中的 checksum；独立检查 FPK 后，再对解包后的真实负载执行同一套回归。用户和网络命名空间测试是必需项，前置条件不满足或回归失败时停止构建，不跳过这些检查。升级回归使用带来源记录的旧控制器夹具，无需另备整份旧 FPK。

CLI 缓存放在 `.tmp/magpie-binaries/`；插件归档、Bun 和许可文件缓存放在 `.tmp/magpie-plugins/`。命中缓存也会重新校验大小和摘要，插件代码仅提取锁定归档中的文件，不依赖仓库外的本地插件工程。已准备好缓存时，可单独做离线核验：

```bash
python3 -B apps/magpie/scripts/prepare-binary.py --offline
python3 -B apps/magpie/scripts/prepare-plugins.py --offline
```

产物为 `build/magpie_0.1.3042-1_x86.fpk`。脚本会阻止覆盖已有同名产物；二进制、FPK、缓存和测试运行数据都不提交 Git。

## 验证范围

`0.1.1275-3` 的历史记录覆盖独立用户、网络命名空间中的生命周期、网关端口和升级交接回归，以及 FPK 解包后的内容和权限检查。隔离测试执行的是非 root 生命周期分支，不等于真实应用中心验收。

`0.1.3042` 已在 WSL Debian 13 通过上游 CLI 大小、SHA-256 与 ELF 校验、完整构建、静态审计（零发现）和 FPK 解包核验；缓存测试 16 项、FPK 元数据测试 25 项通过，暂存树及解包负载各通过生命周期 74 项和网关端口 72 项隔离断言。

`0.1.3042-1` 已通过完整构建、静态审计（零发现）和 FPK 解包核验，插件/Bun 资产测试 9 项通过。新增的离线端到端测试在暂存树和实际解包负载中均通过：在独立用户与网络命名空间中运行真实 Magpie，获取“人设”页及页面资源，通过页面选项 API 保存导入人设，再由回环假 provider 捕获真实网关请求，检查默认不改写、append 注入、off 立即还原，以及停用/删除后的重启保留。另覆盖首次注册保留其他插件、空注册表、同名冲突、损坏 JSON、符号链接拒绝、缺少 Bun 失败和停止后无残留 Bun 子进程。上游钩子 44 项断言和页面逻辑回归已通过。

升级交接回归使用旧控制器夹具配合当前二进制，未模拟真实旧版 FPK 替换和应用中心升级。root 降权分支、真实应用中心安装与升级、包账户重启、桌面入口、真实浏览器交互，以及 Bun 在最低支持 fnOS 上的 ABI 仍待补充验收。构建成功只说明打包与对应检查完成，不代替目标 NAS 上的这些验证。
