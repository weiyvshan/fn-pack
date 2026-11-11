# v2rayA for fnOS

独立应用 `v2raya`，不迁移或覆盖 Clash 的订阅、配置或应用身份。
飞牛包版本 **1.0.0**；上游主程序与配套内核 **2.5.13**，两种版本独立维护。

## 安装与使用

1. 需要飞牛 Python 3.12 应用（安装依赖 `python312`），x86_64 架构。
2. 安装时填写独立的 v2rayA 管理员账号，密码为 12–32 UTF-8 字节；不要复用 fnOS 密码。
3. 桌面入口打开 `http://<NAS地址>:2017/`，使用安装向导创建的账号登录。
4. 在上游 Web UI 导入订阅或节点链接，选择节点后启动代理核心。
5. 上游默认 SOCKS5/HTTP/规则 HTTP 端口分别为 20170/20171/20172，默认仅回环可用。
   给其他局域网设备使用时需在界面启用端口分享，并核对访问范围；不要暴露公网。

管理页使用 HTTP，浏览器登录和订阅凭据应仅在可信内网或 VPN 使用；公网访问需另配 HTTPS。
首次注册在 owner-only 私有目录内的 Unix socket 上完成，账号验证成功才允许公开监听。
已有数据重装或升级保留账号，向导新密码不会重置已有管理员。应用不会自动删除配置或订阅。

## 边界

- 专用非 root 用户/组 `v2raya`，显式 `--lite`，无 root 钩子、setcap 或 systemd 安装。
- 初始化透明代理为关闭，DNS 模式关闭，不主动改变宿主转发、防火墙或网关。
- **本包不提供 TUN/TPROXY 网关功能。** lite 模式本身不是防止管理员修改设置的安全边界；
  请勿在界面开启桌面系统代理或导入其他机器上的特权运行配置。
- 首次启动不需下载 geo 数据，前端嵌在官方二进制中。但这不是“完全无联网行为”：
  上游仍会在启动与周期任务检查版本，订阅更新、测速和部分规则操作也会联网。
- 若首次初始化中断，留下数据库却没有本包初始化标记，应用会拒绝自动接管，防止采用
  未知管理员。请保留数据与错误信息后排查，不要直接删除数据库或伪造标记。

## 系统代理报 GNOME/KDE 错误时

若提示 `could not set up transparent proxy in system proxy mode: no supported desktop environment found`，
它是 lite 模式试图修改桌面代理设置，不是节点认证失败，也不是管理员账号密码有问题。
fnOS 没有 GNOME/KDE 桌面环境，不要为此安装 gsettings 或 kwriteconfig。

- 保持仪表板的“透明代理/系统代理”为“关闭”；需要给局域网设备用时，单独打开“允许局域网的连接”。
- 在调用方填写 NAS 的 IP 与代理端口：SOCKS5 20170、HTTP 20171、规则 HTTP 20172；
  端口如已修改，以“地址与端口”为准。HTTP 2017 是管理页，不是代理端口。
- “正在运行”表示核心已启动，不代表已接管宿主或整个局域网的流量。延迟测速可单独成功。
- 上游保存失败会恢复旧设置并重新读取界面，因此下拉框可能显示“关闭”，同时仍保留刚才的报错。

已用同版真实二进制在 WSL 非 root 环境复现：透明关闭时，`portSharing=true` 保存成功；
启用 `transparentType=system_proxy` 与 `transparent=proxy` 会返回上述错误，旧的关闭状态恢复，
核心继续运行。该复现不是 G480 的远程读取或配置修改。若保持关闭后单独开启端口分享仍失败，
需查看那次具体的错误或请求，不能当作相同原因。

## 上游与 CPU

- 稳定版：v2rayA v2.5.13；源码提交 `3c32891eb390e63e91c35d746a11de88855dae99`。
- 同一官方 Debian 发行内的 `v2raya` 与 `v2raya_core`（Xray 衍生核心），不混用 mihomo。
- 两个二进制实际 Go build-info 均为 `GOAMD64=v1`、`CGO_ENABLED=0`；不是仅看 x64 文件名。
- 归档 size/SHA-256、两个二进制摘要见 `upstream.lock.json`；直接提取 geo 数据及官方图标。
- 不运行 Debian 安装脚本，不修改上游二进制或源码。

## 持久化

- `$TRIM_PKGETC/v2raya`：上游数据库、生成配置和本包初始化标记（私有目录）。
- `$TRIM_PKGVAR/logs/v2raya.log`：应用日志；`run/` 保存锁与进程信息。
- `$TRIM_PKGTMP/bootstrap`：短期私有 socket；初始化后删除 socket。
- 升级前停止应用自己的精确匹配进程；停服不依赖易过期的 PID 文件，不按进程名批量杀。

## 构建与验证

```bash
python3 -B apps/v2raya/scripts/prepare-artifacts.py
sh apps/v2raya/scripts/test-package.sh
bash apps/v2raya/scripts/build-fpk.sh
```

构建仅在 x86_64 Linux/WSL 上执行。资产进入独立 staging；校验下载摘要、CPU 基线、
原始静态审计；调用已校验 fnpack 后逐文件核对实际 FPK 的内容和模式，再输出版本化包与摘要。
`--verify-only` 只读检查缓存，`--output` 仅允许不存在的 staging 目录。

WSL 验证：使用已有非 root 身份（没有创建测试用户），真实二进制完成私有账号初始化、
登录/设置验证、公开管理页就绪、停止、冷启动、丢失 PID 文件处理、升级/重装保留账号，
以及核心孤儿进程的精确清理。源码契约测试与资产正反例另行执行。

**未验证**：G480 上应用中心安装流程、真实 Python312 SDK、fnOS NSS/sg 与 /proc 权限、
实际订阅服务商流量、真实代理连通性、TUN 网关。WSL 成功不代替这些验收。

许可和对应源码见 `THIRD_PARTY_NOTICES.md`，图标来源见 `assets/PROVENANCE.md`。
