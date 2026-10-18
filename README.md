# fn-pack

fnOS 应用打包工作区。当前只收录 deepseek-harness 的打包工程，其余应用后续按同一结构陆续加入 `apps/<appname>/`。

## 目录结构

- `apps/deepseek-harness/` — deepseek-harness 打包工程（manifest、runtime.lock.json、四个锁定源码补丁、构建与自检脚本）
- `.agents/skills/fnnas-app-creator/` — fnOS 打包技能，含 linux-amd64 的 `fnpack` 与审计脚本
- `vendor/runtime-cache/` — 离线运行时缓存：pnpm 与 landlock 原生插件安装包
- `vendor/upstream/` — 上游源码检出位置，**不入库**，由 `bootstrap.sh` 拉取

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

脚本会按 `apps/deepseek-harness/runtime.lock.json` 里记录的上游地址与 commit 拉取源码、校验 commit、再调用构建脚本。产物落在：

```
build/deepseek-harness_0.0.18_x86.fpk
```

把额外参数透传给构建脚本（例如换镜像源）：

```bash
pnpm_config_registry=https://registry.npmmirror.com ./bootstrap.sh
```

## 上游源码手动准备

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git vendor/upstream/deepseek-harness
git -C vendor/upstream/deepseek-harness checkout 687f282e8625c6b8d11ff58211a90524be2e4317
```

## 自检

构建前可就地跑打包工程自检（不需要上游源码）：

```bash
env -u TRIM_PKGHOME -u TRIM_APPDEST -u TRIM_PKGVAR bash apps/deepseek-harness/scripts/test-package.sh
```

环境里若带有 fnOS 应用运行时导出的 `TRIM_*` 变量，必须先清除，否则测试夹具会取到宿主机泄漏值而误判。
