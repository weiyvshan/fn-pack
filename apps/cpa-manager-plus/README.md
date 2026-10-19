# CPA Manager Plus

fnOS 原生双服务包：CPA Manager Plus 提供管理界面，CLIProxyAPI 提供代理服务。

- 飞牛包版本：`1.0.15`，平台：`x86`，声明最低 fnOS：`1.1.8`。
- 上游组件：CPA Manager Plus `1.14.7`、CLIProxyAPI `8.0.32`。
- 管理入口：`18317/management.html`；代理端口：`8317`。
- 版本与摘要以 [manifest](manifest)、[binary.lock.json](binary.lock.json) 为准。
- 打包更新见 [CHANGELOG.md](CHANGELOG.md)，第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 构建

使用 glibc 的 x86_64 Linux，需要 Bash、Python 3.8+、curl、ss、GNU tar/coreutils。
共享 fnpack 与审计工具已在仓库中，不需要 Node、Go 或前端编译链。

在仓库根目录执行：

```bash
(
  for name in "${!TRIM_@}"; do unset "$name"; done
  mkdir -p .tmp
  export TMPDIR="$PWD/.tmp"
  bash apps/cpa-manager-plus/scripts/build-fpk.sh
)
```

首次构建从官方 Release 下载锁定归档，验证归档和最终二进制的字节数、SHA-256，
只提取指定成员到 `.tmp/cpa-manager-plus-binaries/`。缓存命中也重新校验。
构建同时执行缓存回归、生命周期测试、真实 CLIProxyAPI v8 迁移、静态审计与 FPK 检查。
端口 `8317`、`18317` 被占用时生命周期冒烟会明确标为跳过；完整验收需释放测试端口。

产物为 `build/cpa-manager-plus_1.0.15_x86.fpk`，同版本产物受到防覆盖保护。
二进制、缓存和产物不提交 Git。离线构建前需准备匹配的缓存，可单独核验：

```bash
python3 -B apps/cpa-manager-plus/scripts/prepare-binaries.py --offline
```

只运行回归前，先运行不带 `--offline` 的准备脚本，再在上述隔离环境中执行
`bash apps/cpa-manager-plus/scripts/test-package.sh`。

## 安装与维护

通过 fnOS 应用中心手动安装 FPK；管理员与客户端密钥由安装向导设置，不写入仓库。
升级保留配置、凭据和使用数据，不主动把旧配置改为 v8；首次成功的 v8 管理写入负责迁移。

升级前备份配置，并保存同一时间点的数据库与归档。已有大库的新延迟覆盖索引需要
先通过应用中心停止服务，再对备份确认后的数据库离线执行
`cpa-manager-plus cleanup-derived --db-path <数据库路径>`；`compact-usage` 不是替代命令。
维护完成后通过应用中心启动服务，不直接修改安装目录。

FPK 构建成功不代表完整设备验收；安装、升级、冷启动、管理入口与业务调用仍须单独核对。
已停用的凭证时段插件和历史 UI 补丁不进入发布源码。
