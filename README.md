# fn-pack

这个仓库维护 fnOS 应用的打包工程。应用本身来自各自上游，这里补充 fnOS 需要的安装配置、生命周期脚本和构建流程。

安装包从 [Releases](https://github.com/weiyvshan/fn-pack/releases) 下载。仓库保留打包源码和锁文件，不提交生成的 FPK、构建缓存或设备备份。

## 应用

点击应用名称查看安装、升级和构建说明。

| 应用 | 打包方式 | 更新记录 |
| --- | --- | --- |
| [DeepSeek Harness](apps/deepseek-harness/README.md) | 原生应用，从锁定源码构建 CLI 和 Web | [CHANGELOG](apps/deepseek-harness/CHANGELOG.md) |
| [CPA Manager Plus](apps/cpa-manager-plus/README.md) | 原生双服务，采用上游发布的二进制 | [CHANGELOG](apps/cpa-manager-plus/CHANGELOG.md) |
| [Sub2API](apps/sub2api/README.md) | Docker 应用，使用锁定的镜像 | [CHANGELOG](apps/sub2api/CHANGELOG.md) |

## 安装

在 Releases 中选择对应应用和版本，下载 `.fpk` 与同一版本的 `SHA256SUMS`。将两个文件放在同一目录后校验：

```bash
sha256sum --check SHA256SUMS
```

校验通过后，在 fnOS 应用中心手动安装 FPK。升级前先看应用说明中的数据保留和备份要求，涉及数据库迁移的版本尤其要留好备份。

私有仓库的安装包需要有仓库访问权限才能下载。CI 构建通过只说明打包和相关检查完成，安装、升级、冷启动及业务功能仍要在目标 NAS 上验证。

## 本地构建

仓库附带的 fnpack 是 Linux amd64 版本，本地构建请使用 x86_64 Linux。各工程的依赖、环境准备和回归命令见上面的应用文档，构建入口分别是：

- DeepSeek Harness：[bootstrap.sh](bootstrap.sh)。按锁定的上游提交准备源码，再构建运行时和 FPK。
- CPA Manager Plus：[build-fpk.sh](apps/cpa-manager-plus/scripts/build-fpk.sh)。下载并校验官方二进制，再装配安装脚本和配置。
- Sub2API：[build-fpk.sh](apps/sub2api/scripts/build-fpk.sh)。装配 Compose、镜像引用和安装脚本；打包时不启动 Docker，也不下载镜像。

DSH 需要 Node.js 和 C/C++ 工具链，还会运行真实的 Landlock 内核测试。它比另外两个工程更吃内存，本地构建建议预留至少 16 GB。

如果在 fnOS 应用自带的终端中构建，先清除继承的 `TRIM_*` 环境变量，避免测试误用宿主应用的目录。具体操作见工程文档，不要在已安装应用的目录里构建或修改文件。

产物统一放在 `build/`，命名为 `<appname>_<version>_<platform>.fpk`。下载的源码、依赖和构建临时文件放在 `.tmp/`；缓存使用前仍会校验，删除后下次构建会重新准备。

## 发布

在 [Actions](https://github.com/weiyvshan/fn-pack/actions) 中选择对应应用的工作流，手动运行可做测试构建。FPK、校验文件和日志会保存为构建附件，不会创建 Release。

正式发布使用 `<appname>-v<飞牛包版本>` 格式的 tag，例如 `sub2api-v1.18`。这里用的是应用 `manifest` 中的飞牛包版本，不是上游程序或镜像的版本。

发布前先完成版本更新和检查，将审核通过的源码提交并推送到 `master`，再给对应提交打版本 tag。工作流会核对 tag 与安装清单，构建成功后再次校验产物摘要，最后创建 Release 并上传 FPK 和 `SHA256SUMS`。

已发布的 tag 保持不动，工作流也不会覆盖已有 Release。需要调整包内容时，递增飞牛包版本后再发布。

使用和构建说明放在各工程的 README，打包变化记在 CHANGELOG，安装清单只保留本版摘要。更新上游依赖时，一起核对锁文件、测试和更新记录，避免多处版本信息各写各的。
