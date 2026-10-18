---
name: dsh-maintenance
description: "飞牛 OS（fnOS）上 deepseek-harness 应用的运维方案，不是通用 Linux 运维手册。覆盖三类高频故障的诊断与修复：插件动态注册资源对扫描器不可见（404 non-json）、跨属主文件访问失败、前端先于后端就绪的瞬时错误。本技能随包投放于应用目标的 builtin-skills/dsh-maintenance/，由启动器经 DSH_BUNDLED_SKILL_DIR 暴露。"
whenToUse: When operating deepseek-harness on fnOS and a panel fetch returns HTML instead of JSON, files are inaccessible across owners, or transient errors appear after plugin install / hot reload.
---

# DSH Maintenance（fnOS 专用）

**适用范围声明**：本技能是**飞牛 OS（fnOS）应用中心里 deepseek-harness 应用的运维方案**。文中路径布局（`/vol<N>/@apphome`、`/vol<N>/@appdata`、`/vol<N>/@appcenter`、`/var/apps/<app>`）、`TRIM_PKGVAR` / `TRIM_PKGHOME` / `TRIM_APPDEST` 等环境变量、AppUsers 组与应用专用 UID 都属 fnOS 应用中心约定。**卷序号与应用 UID 由安装实例分配，不是固定值**：G480 实例为 `/vol2`、uid 950/gid 945，YDYNAS 实例为 `/vol1`、uid 924/gid 919。这些约定**不适用于通用 Linux 发行版或其他打包形态**，在其他环境只能参考诊断思路，命令不能照搬。

## 诊断总则

1. 先以目标身份实测，再看元数据：`sudo -u <appuser> cat <file>` 优先于 `ls -l`。OneSSH 环境下 sudo 必须走 `sudo_exec`（普通 exec 的 sudo 无 TTY 会失败）。
2. 权限问题查三层：属主/权限位（`ls -ln`）、POSIX ACL（`getfacl -p`）、上级目录遍历权。
3. 服务端注册问题用 curl 判 Content-Type：`application/json` = 正常；`text/html` 或 404 = 路由未注册。
4. 修复取最小改动；改动前备份（`*.bak`）；结论写入对应主机的 memory bank。

## 模式 A：动态注册资源对扫描器不可见

机制：插件运行时注册资源（如 `ctx.inject(["webServer"], (host) => host.webServer.register({ kind: "exact", path }, label))` 注册 HTTP 路由），网关静态扫描拿不到 → 请求落到 SPA 兜底，前端报 `404 non-json`（响应体是 index.html）。

修复：已知插件仅在已安装 profile 依赖键与安装目录 `package.json.name` 一致时由网关自动映射，例如 `dsh-better-sidebar` 对应 `/sidebar/`。未知动态路由须先取得管理员确认，再用包内 `gateway-compat.js` 的 `profileDependencies`/`packageDirectory` 验证依赖与实际 manifest 身份，最后以 `setPlugin` + `writeRegistry` 写入小写一级命名空间；空 roots 可撤销。registry 每次响应热读，**页面刷新即可，无需重启**。

时机注意：上游 `plugin_manager` 按插件 reload 策略更新运行态；live 更新期间前端 bundle 仍可能先于后端路由就位。这个窗口期的 404 属瞬时错误（见模式 C）。

## 模式 B：跨属主文件访问失败

机制：资源属主 ≠ 服务账号，700/750 目录阻断遍历，服务读不到文件。

修复优先级：① `chown -R <appuser>:<appgroup> <dirs>` 统一属主（最简单）；② POSIX ACL 仅授权 `setfacl -R -m u:<appuser>:rx <dir>`（需保留原属主时用）。二者等效取一，不要叠加。验证：`sudo -u <appuser> head -2 <file>` 实读成功。

fnOS 实例（G480，2026-09-16）：`/vol2/@apphome/deepseek-harness/.dsh/skills` 下 13 个 lenovo 属主技能目录统一 chown 为 deepseek-harness:deepseek-harness（uid 950/gid 945），文件 644、目录 750 权限位不动。

## 模式 C：前端先于后端就绪

热更新或重启窗口期出现瞬时错误（404、加载失败等）：服务稳定后刷新页面即恢复，不做多余修复。判据：同一请求稍后重试成功 = 窗口期问题。

## 本技能的存放约定

本技能随 FPK 投放于应用目标的 `builtin-skills/dsh-maintenance/`，由 `dsh-launcher` 经 `DSH_BUNDLED_SKILL_DIR` 暴露为随包技能根（`dsh-skill-filesystem` 按 rank 600 加入该根），**不复制进 `${DSH_HOME}/skills`**。该目录位于 App Center 安装树内，禁止设备侧改动：修改必须回到打包工程源码 `app/builtin-skills/dsh-maintenance/SKILL.md`，版本号 +1 后重新打包并在应用中心重装，升级会整体替换本目录。
