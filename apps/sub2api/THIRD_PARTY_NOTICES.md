# Third-party sources and notices

本工程只将 fnOS 清单、Compose、生命周期钩子、入口配置和许可证文本装配为 FPK，不把 Docker 镜像或上游可执行文件嵌入包内。运行时由 fnOS Docker 工程按 [image.lock.json](image.lock.json) 中的不可变引用拉取三个镜像；tag 名称本身不作为字节身份。

## Sub2API 0.2.24

- 官方仓库：[Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api)。
- 正式版本：[v0.2.24](https://github.com/Wei-Shaw/sub2api/releases/tag/v0.2.24)。
- 附注标签对象：`7515db6dc56c2a6120dfb7abed70ef089ebc1457`。
- 对应源码提交：[`5c2982a81b46e2142d0143d2f83c1ce9c4da1d24`](https://github.com/Wei-Shaw/sub2api/tree/5c2982a81b46e2142d0143d2f83c1ce9c4da1d24)。
- 镜像：`docker.io/weishaw/sub2api:0.2.24`；多架构索引为 `sha256:c1acdd4cd1c328e6df20e513944d72fff641d4ae8c07d207458156c97c74784a`，amd64/arm64 平台摘要以锁文件为准。
- 核验日期：2026-11-24。官方 Registry 返回的索引按响应摘要核验，平台清单和配置 blob 再逐项核验 SHA-256 与描述符声明的大小，并与 Docker Hub 的 tag 元数据交叉核对；两个平台的 OCI `revision` 均等于上述源码提交，`version` 均为 `0.2.24`。
- 上游 [LICENSE](https://github.com/Wei-Shaw/sub2api/blob/5c2982a81b46e2142d0143d2f83c1ce9c4da1d24/LICENSE) 为 GNU Lesser General Public License v3 文本，随包原文位于 [app/LICENSE](app/LICENSE)，SHA-256 为 `a5681bf9b05db14d86776930017c647ad9e6e56ff6bbcfdf21e5848288dfaf1b`。与 0.2.21 相比字节未变；本工程未修改镜像内的上游程序。

## 不变的数据库与缓存镜像

本次只更新 Sub2API 镜像；下列锁定内容沿用飞牛包 1.21，不追随可变 tag 自动升级。

| 服务 | 官方镜像 tag | 锁定来源 |
| --- | --- | --- |
| PostgreSQL | `docker.io/library/postgres:18-alpine` | [docker-library/postgres](https://github.com/docker-library/postgres/tree/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/18/alpine3.24)，锁定来源版本 `18.6-alpine3.24` |
| Redis | `docker.io/library/redis:8-alpine` | [redis/docker-library-redis](https://github.com/redis/docker-library-redis/tree/0a24b09f88a6cb8feaf130d4eca7bd6b9b4c73a3/alpine)，锁定来源版本 `8.10.0-alpine` |

三个镜像的索引、平台摘要、来源修订和版本映射均保留在锁文件中。本文件是来源说明，不替代 PostgreSQL、Redis、镜像基础系统和各项传递依赖自身的许可证、通知及适用的源码提供义务；这些内容以所锁定镜像和对应上游源码中的声明为准。
