# Sub2API

Sub2API 的飞牛 Docker 打包工程，由应用中心管理网关、PostgreSQL 和 Redis 三个容器。
这里只维护可复现的打包输入、测试与说明，不收录 Docker 镜像、FPK 或构建缓存。

## 当前版本

| 项目 | 当前值 |
| --- | --- |
| 飞牛包 | `1.20` |
| 上游 Sub2API | `0.2.19` |
| 包平台 | `all`，镜像锁覆盖 Linux amd64、arm64 |
| 服务入口 | `http://<NAS地址>:18081` |
| 数据服务 | PostgreSQL 18、Redis 8 |
| 最低 fnOS 声明 | `1.0.0` |

镜像、平台摘要与源码来源统一记录在 [image.lock.json](image.lock.json)，版本变化见 [CHANGELOG](CHANGELOG.md)。
平台和系统版本声明不代表全部设备已验证；当前 `1.20` 的应用中心实机安装、升级和运行验收尚未完成。

## 部署与数据

1. 先在目标 fnOS 安装并启动 Docker，确认设备可拉取锁定镜像，端口 `18081` 未被占用。
2. 通过应用中心安装 FPK，向导填写管理员邮箱，以及 `12–72` 个允许 ASCII 字符的口令。
3. 口令允许字母、数字和 `._~!@%^+=,:-`；启动后从桌面入口或上述地址访问。

数据库、Redis、JWT 和 TOTP 凭据由安装流程生成；文件权限为 `0600`、私有目录为 `0700`，只读挂载进容器。
持久数据位于声明的 `sub2api` 共享目录，应用、数据库和 Redis 分别使用 `data`、`postgres`、`redis` 子目录。
升级保留挂载和运行凭据；保留数据重装会沿用既有管理员，并复用应用数据中的 JWT/TOTP 密钥。
卸载或重装前确认共享目录的保留选项和备份，保留数据不等于重置管理员口令。
旧初始化锁的自动修复只处理用户表存在且严格为空的情形，正常用户库保持原状。

## 升级与维护

- 升级前保存同一时间点的 PostgreSQL 数据库与应用数据备份，并保留恢复所需的凭据。
- 上游首次启动会自动执行数据库迁移；`0.2.19` 新增迁移 247（管理员 API Key 表）和 248（分组按张计费字段）。回退旧版本必须恢复匹配备份，仅更换镜像不撤销迁移。
- `0.2.19` 的 Gemini 默认目录已移除 2.x 系列；仍需使用这些模型时，在账号白名单或模型映射中显式配置。OpenAI / Composite 分组的按张计费默认关闭，仅对专用图片端点生效。
- 跨越 `1.17` 升级时检查 API Key 创建限制、余额在途预留和自定义 max-effort 定价。
- 升级到 `0.2.18` 会执行迁移 246 打开已有 Gemini / Antigravity 分组的生图开关；混合分组需要手动开启，否则生图请求返回 400。
- OAuth/SetupToken 账号依赖 GPT-5.5 时先配置模型重映射，否则可能返回 `model_not_found`；API-key 账号不受该项调整影响。
- 通过应用中心安装、升级和启停，不直接修改已安装包，也不用手工 Compose 操作替代包升级。

应用中心偶发 Compose 创建零进展或平台 CLI 报错，应先核对应用中心任务与 Docker 状态，不据此改写安装文件。
对外访问前检查 CORS、可信代理与 URL 白名单配置；定价更新联网失败时会使用内置数据。

## 构建与检查

在仓库根目录使用 x86_64 Linux、Bash、Python 3、tar 和 coreutils，并保留仓库内置 fnpack 技能目录。
打包只装配 Compose、钩子与镜像引用，不需要本机运行 Docker，也不编译上游服务。
以下命令在独立子 Shell 清除继承的 `TRIM_*`，并将临时数据限制在仓库目录：

```bash
(
  set -e
  for name in "${!TRIM_@}"; do unset "$name"; done
  export TMPDIR="$PWD/.tmp"
  mkdir -p "$TMPDIR"
  bash apps/sub2api/scripts/test-package.sh
  bash apps/sub2api/tests/installer.test.sh
  bash .agents/skills/fnnas-app-creator/scripts/audit_fnos_project.sh --project-path apps/sub2api --format json
  bash apps/sub2api/scripts/build-fpk.sh
)
```

安装器回归夹具要求临时目录以 `/vol` 开头，本 NAS 仓库路径满足；GitHub 工作流只在临时托管 runner 准备该夹具目录。
Shell 脚本是权威实现；PowerShell 入口只转发，不维护第二套构建与校验逻辑。
构建会校验镜像锁、声明、钩子执行位、私有凭据目录及最终 FPK 内层校验值。
输出为 `build/sub2api_1.20_all.fpk`；脚本拒绝覆盖同版本产物，原产物应独立保留和分发。
源码检查、构建成功与历史旧版设备记录均不替代当前版本的实机验收。

## 维护约束

运行内容或打包契约变化时递增包版本；仅整理仓库文档不改版本，也不重写已分发产物。
更新镜像时同步锁文件、Compose 引用、测试与版本记录，保留上游版本和飞牛包版本的区别。
保留空凭据目录中的 `.keep`，不将生成的密钥、会话数据或设备专属文件加入源码。
第三方许可证随包保存在 [LICENSE](app/LICENSE)，更新时核对文本与锁定来源。
