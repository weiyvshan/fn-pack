# fn-pack

fnOS 应用打包工作区。当前只收录 deepseek-harness 的打包工程，其余应用后续按同一结构陆续加入 `apps/<appname>/`。

## 目录结构

- `apps/deepseek-harness/` — deepseek-harness 打包工程（manifest、runtime.lock.json、四个锁定源码补丁、构建与自检脚本）
- `.agents/skills/fnnas-app-creator/` — fnOS 打包技能，含 linux-amd64 的 `fnpack` 与审计脚本
- `.tmp/deepseek-harness-runtime-cache/` — 按锁定 URL 下载的 pnpm 与 Landlock 安装包缓存，**不入库**
- `.tmp/deepseek-harness-upstream/` — 上游源码检出位置，**不入库**，由 `bootstrap.sh` 拉取
- `build/` — 最终 FPK 构建产物，作为 GitHub Release 附件分发，不提交到 Git

## 目标机要求

- **x86_64 Linux**。Windows 用 WSL2；macOS 走不通：`fnpack` 只有 linux-amd64 版本，构建链还要实跑 5 个真实 Landlock 内核用例。
- Node.js >= 22.19（推荐 24）
- 内存 >= 16 GB。`tsc -p tsconfig.host.json` 是全程内存峰值，本机 8 GB 环境下该步骤跑满 97 分钟后被 OOM 杀掉。
- git、python3、tar、coreutils、bash
- 可访问 GitHub（拉取上游源码约 470 MB）

## 构建

```bash
./bootstrap.sh
```

脚本会按 `apps/deepseek-harness/runtime.lock.json` 里记录的上游地址与 commit 拉取源码、校验 commit，再调用构建脚本。缺少 pnpm 或 Landlock 安装包时，会按锁文件中的 URL 下载到 `.tmp/deepseek-harness-runtime-cache/`；包括缓存命中在内，构建前都会校验 SHA-256 与 SHA-512 integrity。下载需要 curl 或 wget，以及访问 npm registry 的网络。

`.tmp/` 是可删除的构建临时目录；删除后下次构建会重新拉取源码和依赖。GitHub Actions 可用 `actions/cache` 缓存运行时安装包，缓存 key 应包含系统、架构和 `runtime.lock.json` 的哈希；缓存未命中不影响构建正确性。

产物落在：

```
build/deepseek-harness_0.0.19_x86.fpk
```

把额外参数透传给构建脚本（例如换镜像源）：

```bash
pnpm_config_registry=https://registry.npmmirror.com ./bootstrap.sh
```

## GitHub Actions 构建与发布

工作流位于 `.github/workflows/release.yml`：

- **测试构建**：在 Actions 页面选择 `Build and release fnOS FPK` → `Run workflow`。只构建并上传 FPK、校验文件及日志，不创建 Release。
- **正式发布**：推送与 manifest 版本完全一致的 tag，例如：

  ```bash
  git tag deepseek-harness-v0.0.19
  git push origin deepseek-harness-v0.0.19
  ```

- 只有 tag 构建成功且产物校验通过，发布 job 才会创建 Release 并附上 FPK 与 `SHA256SUMS`。不会静默覆盖已有 Release。
- 依赖压缩包由 `actions/cache` 缓存；不缓存上游工作树，避免可变源码状态进入发布。
- 默认使用 `ubuntu-24.04` 与 Node.js 24.20.0。低于约 14 GiB RAM 时，工作流检查磁盘余量，并使用 runner 的免密 sudo 补足 RAM + swap 至至少 18 GiB，同时预留 10 GiB 构建磁盘空间；不关闭既有 swap。空间不足时，仅在 GitHub 托管的临时 runner 上按需移除固定路径的 Android、.NET、Haskell 预装 SDK，清理后重新检查空间；不会对 self-hosted runner 自动清理。该低内存方案仍待 GitHub 实跑验证，可能明显变慢或 OOM，失败时应考虑至少 16 GB 的 larger runner。构建超时为 180 分钟，资源诊断和 `/usr/bin/time -v` 统计随日志上传。
- 手动构建仅需读取仓库权限；发布 job 才获得 `contents: write`，无需额外 PAT。私有仓库的 Release 附件仍受仓库访问权限限制。
- CI 成功不代表真机 UI、冷启动、升级与沙箱功能全部验收通过。发布说明附带应用变更记录及验证限制。

## 上游源码手动准备

```bash
mkdir -p .tmp
git clone https://github.com/deepseek-ai/deepseek-harness.git .tmp/deepseek-harness-upstream
git -C .tmp/deepseek-harness-upstream checkout 687f282e8625c6b8d11ff58211a90524be2e4317
```

## 自检

构建前可就地跑打包工程自检（不需要上游源码）：

```bash
env -u TRIM_PKGHOME -u TRIM_APPDEST -u TRIM_PKGVAR bash apps/deepseek-harness/scripts/test-package.sh
```

环境里若带有 fnOS 应用运行时导出的 `TRIM_*` 变量，必须先清除，否则测试夹具会取到宿主机泄漏值而误判。
