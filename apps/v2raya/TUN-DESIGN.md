# 非 root TUN 集成：证据与设计草案

状态：核心权限实验通过，尚未形成可部署 TUN 版本；现有 1.0.0 lite 包不变。

## 已执行的隔离实验

环境：WSL Debian，独立 `unshare --net` 网络命名空间，初始仅 lo、无路由。
使用已校验官方 2.5.13 核心。编排进程为 root，仅用于创建命名空间和降权；
核心四个 UID 均为 65534，未创建真实用户，未设置宿主文件 capabilities。

```
unshare --net python3 -B apps/v2raya/tests/probe-tun-capabilities.py \
  /absolute/path/to/v2raya_core
```

| 核心有效权限 | 创建 tun0 | 退出后清理 |
| --- | --- | --- |
| 无 capabilities | 失败，operation not permitted | 无设备 |
| 仅 CAP_NET_ADMIN（CapEff 0x1000） | 成功 | 设备消失 |

测试只证明核心创建/配置 TUN 与退出释放，不证明代理数据通路、自动路由、DNS、
G480 capability 授权、NAS 冷启动/升级和失联回滚。没有修改宿主默认路由或 NAS。

## 上游分工（v2.5.13）

源码基准：3c32891eb390e63e91c35d746a11de88855dae99。

- `core/hint/proxy/tunmips/device.go`、`addr_linux.go`：核心创建 TUN、分配地址、拉起接口。
- `service/kernel/v2ray/tun_core.go`：服务管理路由生命周期；autoRoute=false 改为执行用户脚本。
- `service/kernel/v2ray/tun_core_linux.go`：服务调用外部 ip，使用 tun0、路由表2020、
  优先级7000/7001/7005/7010/7020及 mark0x80，并记录撤销命令。
- `service/conf/environmentConfig.go`：非 root 自动进入 lite；passcheckroot 只绕过身份检查，
  不授予权限。不要以传一个参数冒充完整授权实现。
- `gui/src/views/settings/options.ts`：lite 隐藏 TUN；`settings/model.ts` 加载时强制 system_proxy。
- `service/kernel/v2ray/transparent.go`：lite 后端并未禁止 TUN，但开始设置前会清理残留规则。
- `service/kernel/v2ray/tun_exclude.go`：允许用户配置 setup/teardown 脚本，不做权限降低。

## 为什么不能直接 setcap 整个服务

给服务文件设置 permitted/effective capabilities，不等于普通 ip/sh 子进程自动继承这些权限。
反之，如果给整个服务 ambient capabilities，用户配置的脚本及插件子进程也可能获得网络权限。
因此不能把完整 Web 服务与可编辑脚本都纳入受信任的特权边界。

仅设置 autoRoute=false、dnsMode=off 也不是无网络写入保证：启动与透明代理设置前仍会尝试
清理表2020、策略规则、iptables/nftables规则。故不能靠两个设置值安全复用一个提权服务。

## 拟定方向（未实施）

1. 管理服务始终普通用户、无 ambient capabilities；前端能力显示与后端策略须一致修改。
2. 核心只获取已证明必要的 CAP_NET_ADMIN，不默认授予 SYS_ADMIN 或 DAC_OVERRIDE；
   独立保护核心的可执行文件与目录，并核验 ACL，不能仅相信 target 的 root 属主。
3. 路由由 root 私有路径下的窄接口帮助进程管理，输入结构化且字段白名单；不执行任意 shell，
   不接受任意 ip/nft 命令、程序路径或用户脚本。
4. 帮助进程记录每次新增规则的完整选择条件和所有权，冲突即失败；绝不整表 flush 或宽泛删除。
5. 默认 TUN 关闭。先验证 NAS 本机模式，再单独处理局域网转发、IPv6 与 DNS接入。
6. 首次启用需明确确认、超时回滚以及独立停止/救援入口；测试覆盖核心崩溃、服务崩溃、
   升级中断、断电残留、错误配置和与已有路由规则冲突。
7. 安装特权入口走 fnOS 支持的注册方式并做受保护内容链审核；不能复用当前 package 用户钩子
   假装可执行 setcap。未解决该注册契约前不交付“已支持 TUN”的包。

这比给 mihomo 内核直接授权多一层集成，因为 v2rayA 把操作系统路由管理放在服务侧。
严格的核心隔离还可考虑继承 TUN FD 的方案，但上游当前没有此接口，需要额外核心改造。
