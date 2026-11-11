# 本地验证记录（不代替 G480 实机验收）

## 产物

- 飞牛包版本：1.0.0；上游 v2rayA 与配套核心：2.5.13。
- FPK：build/v2raya_1.0.0_x86.fpk
- 字节数：32,746,587
- SHA-256：f9de21cdcffad523d573fc79b4f4dc1537bb136e84e69745a6cd83c5ab939230
- 环境：WSL Debian-13 x86_64；随仓库 fnpack-1.2.3-linux-amd64。

## 已执行

- 源契约、资产验证及生命周期测试：25 项（其中 native smoke 在普通运行时跳过）。
- 从最终 FPK 提取 runtime，再以已有 nobody 非 root 身份运行生命周期测试：18 项通过，
  包含真实服务、配套内核、私有管理员初始化、API 认证/设置、启动/停止、冷启动、
  missing PID 与 orphan core、升级/重装保留账号。与前述单元测试有重叠，不累加为独立项目数。
- 两个原生二进制 Go build-info：GOOS=linux、GOARCH=amd64、GOAMD64=v1、CGO_ENABLED=0。
- 临时 staging 原始 fnOS 审计：0 findings。
- FPK 逐文件内容与模式和 staging 一致；manifest appname/version 核对通过。
- 未执行 Debian 安装脚本；未修改 NAS 或现有 Clash 工程。

## 待验证

G480 实际安装/启动、Python312 SDK 路径与 ABI、包 UID/GID 与 sg、/proc 可见性、pidfd
支持、注册桌面入口、真实代理流量及业务协议。WSL 测试使用 Python 3.13 与测试身份映射，
不宣称已经验证 fnOS shell wrapper 或真实包用户。无 TUN/TPROXY 验收。

此产物是本地测试交付；没有提交、打 tag 或发布 GitHub Release。生命周期、权限清单和锁文件
仍需按仓库约定人工阅读后才能合入或发布。
