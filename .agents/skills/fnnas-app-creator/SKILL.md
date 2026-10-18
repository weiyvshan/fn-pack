---
name: fnnas-app-creator
description: '创建、审计、构建和实机验证飞牛 fnOS 应用 FPK。用于将 GitHub 项目或本地程序打包为原生或 Docker 应用，以及修复 manifest、生命周期、UID/GID、ACL、离线依赖、systemd、升级、冷启动和桌面入口问题；与 fnos 技能协作完成应用中心安装与启停。'
---

# 飞牛应用打包

将源码、可追溯 FPK 与实际运行状态分开验证。优先复用现有工程，尊重用户选择的原生或 Docker 运行方式；不以容器替代明确要求的原生部署。

## 读取路线

| 工作 | 先读 |
| --- | --- |
| 新建工程、manifest、身份、ACL、资源、入口或 SDK | [平台契约](references/platform-contract.md) |
| 原生服务、特权控制器、钩子、升级、持久化 | [生命周期契约](references/lifecycle-native-security.md) |
| 安装、升级、CLI/UI 交接、实机验收 | [应用中心交接](references/fnos-app-center-handoff.md)；随后加载 `fnos` 并读其 App Center 入口 |
| 构建或运行失败 | [故障定位](references/troubleshooting.md) |

先读取脚本再执行；使用 `bash` 运行 shell 工具、`python3 -B` 运行 Python 工具。不要下载或安装宿主系统包。

## 执行顺序

1. 确认工作区、目标 NAS、fnOS/架构、原生或 Docker 模式、应用与发布者身份、当前端口和已有版本。读取相关文件和现场状态，保留用户未提交改动。
2. 预检真实 SDK 执行、Python/Node 版本、主组与专用组、可用端口。应用登记存在不等于 target 或解释器可用；已有应用的端口占用先核对归属，不直接停进程。
3. 将程序放入 `app/`；配置和持久数据分别放在应用 `etc`、`var`。不手工选卷绕过 `TRIM_*`。App Center 安装树只读检查，持久行为变更走源码、版本递增、SDK 构建与应用中心升级。
4. 原生服务明确应用 UID/专用 GID、固定 SDK 路径、`Type=exec` 和健康就绪检查。验证实际 PID/argv、停止后的端口释放；固定端口的旧进程在升级前停止。分清新元数据脚本与旧 target 的组合。
5. 特权入口只运行经完整审核的代码。不要信任 target 的 root 属主或 775 模式能阻止应用用户改写；检查 ACL 与祖先，root 控制文件使用单独严格权限的外部命名空间。内容 pin 需绑定 FD 读取的同一缓冲区，历史 pin 仅用于必要的固定阶段。
6. 核对资产指纹链，跑生命周期正负例及原始工程审计；审计问题全部解决或经用户明确评审后再分发，不过滤或降低告警来取得零问题。未知特权实现需要实际审查，不因生成新摘要而自动被接受。
7. 使用 SDK 构建，产物落在进程工作目录。先检查目标产物不存在，立即按版本重命名并保存 SHA-256、审计 JSON。解包核对实际字节、模式、依赖与数据排除。记录上游版本与 FPK 版本，分别追溯。
8. 通过 `fnos` / 应用中心安装，等待真实任务终态。验收首次启动、完整停止、冷启动、旧版升级、持久化、运行身份、健康接口及注册网页入口。将实际通过项与未执行项分别报告。

## 原生结构参考

使用 [exec 单元模板](assets/native-exec.service.in) 与 [字段编码函数](scripts/systemd_fields.py) 作为结构参考。`TARGET_PATH`/`ROOT_ENV_PATH` 用 `unit_path`，Python/server/state 的词列表项用 `unit_word`；ExecStart 的 `:` 前缀保持美元符号字面值。验证固定身份、所有占位符均已消除、实际 unit 解析成功及控制文件信任边界。模板不包含 root 生命周期加载器，也不自动进入审计允许列表；每个应用实现仍需完整审核。

## 可执行检查

工具输出 JSON，失败退出码非零；除现有 SDK 构建器外，以下工具不修改应用、指纹或服务。预检只执行隔离 SDK/标准库 ABI 与 NSS 检查，不执行项目或 site-packages；业务依赖导入、ACL、root 控制文件及浏览器入口仍须按对应契约取证。运行检查只证明当前快照，不替代升级、冷启动和持久化完整矩阵。

依赖预检，在目标 NAS 执行，按项目所需版本替换参数；新包尚无账户时先省略身份参数：

```bash
python3 -B scripts/native_preflight.py \
  --python /var/apps/python312/target/bin/python3.12 --python-version 3.12 \
  --node /var/apps/nodejs_v22/target/bin/node --node-major 22 \
  --identity tripstar --group tripstar
```

仅安装前要求空闲端口时加 `--port 17860`。升级中已归属于旧版本的监听不是环境损坏，也不是终止未知进程的许可。

固定内容指纹链，三条边仅作为已审核实现的实例；工具只核对实际字节，不重写 holder：

```bash
python3 -B scripts/check_content_pins.py --project-path PROJECT \
  --edge cmd/main expected app/bin/lifecycle.py \
  --edge app/bin/lifecycle.py TEMPLATE_SHA256 app/systemd/fnos-tripstar.service.in \
  --edge app/bin/lifecycle.py SETUP_SHA256 app/bin/setup-runtime.py
```

原始审计、SDK 解析与技能回归：

```bash
bash scripts/audit_fnos_project.sh --project-path PROJECT --format json
bash scripts/resolve-fnpack.sh
bash scripts/test_fnos_skill.sh
python3 -B scripts/validate_skill.py SKILL_DIRECTORY
```

运行验收，在目标 NAS 执行；UID/GID 从现场专用账户获得，不硬编码复制实例值：

```bash
python3 -B scripts/check_native_runtime.py \
  --unit fnos-tripstar.service --uid 923 --gid 918 --port 17860 \
  --exe /var/apps/python312/target/bin/python3.12 \
  --argv-token gunicorn --argv-token backend.app.api.main:app \
  --health-url http://127.0.0.1:17860/health
```

通过受支持控制面停止后，使用相同 unit/uid/gid/port 参数并加 `--state stopped`，不带健康、exe、argv 参数。检查工具从不启动、停用或重启服务；访问其他用户进程信息需要的权限通过 OneSSH 获得，不使用本地 sudo。

## 发布证据

至少保留以下结果，并明确归属源代码、FPK、安装树还是运行进程：

- 上游提交、FPK 版本、大小、SHA-256、实际安装版本与设备版本。
- 原始审计 JSON、正负例结果、实际 unit 解析和原生导入/ABI 验证范围。
- 应用中心任务成功及 `running`，不是仅有登记或 `status=start`。
- 新 PID 的实际 UID/GID、可执行文件、argv、端口归属和健康响应；停止后 PID=0 且端口空闲。
- 冷启动和升级后的同一持久标记/设置证据；不输出密钥或 Cookie。
- 通过注册入口实际打开网页的 URL、页面与关键资源结果。完整业务调用需要外部 API 配置时单独说明。

## 维护技能

执行结构校验和完整回归后再提交技能变更。工作区 `.agents/skills/fnnas-app-creator` 由 DSH 的项目技能发现机制加载，不复制上游 `fnos` 或改安装目录；实际调用成功才报告已发现。新增可复用模板仍需单独审核其特权边界，不把 TripStar 固定 AST 合同泛化为任意应用的放行规则。
