# 第三方许可声明

- **Magpie CLI 0.1.3771** — Copyright (c) 2026 yetone，MIT License。
  - 项目：<https://github.com/yetone/magpie>
  - 官方发布：<https://github.com/yetone/magpie-releases/releases/tag/v0.1.3771>
  - 随包提供官方 Linux amd64 CLI，资产 URL、大小与 SHA-256 见 `binary.lock.json`；上游许可文本见 `LICENSE`。

- **agent-purge** — [ZiChuanLan/agent-purge](https://github.com/ZiChuanLan/agent-purge)，MIT License。
  - 源码发布 `v0.2.19`，提交 `09ce906fc9aeee287c9d4891dd0b96bf2db12fb6`；`magpie-plugin` 自身版本为 `0.1.0`。
  - 仅分发钩子与页面文件，未修改这些上游源码；人设清单生成为空，不包含构建机个人数据。
  - 许可随包位于 `app/licenses/agent-purge-LICENSE`，归档来源与摘要见 `plugin.lock.json`。

- **Bun 1.4.2** — [oven-sh/bun](https://github.com/oven-sh/bun/tree/bun-v1.4.2)，Bun 本体 MIT，静态链接组件另有 LGPL、BSD、Apache 等许可。
  - 分发官方 Linux x64 baseline 二进制，资产来源、大小与 SHA-256 见 `plugin.lock.json`。
  - 上游完整分发说明与第三方许可链接随包位于 `app/licenses/bun-LICENSE.md`；包含 JavaScriptCore/WebKit 的源码与重链接说明，不将整个二进制简单归为 MIT。
  - Bun 源码与构建方法：[bun-v1.4.2](https://github.com/oven-sh/bun/tree/bun-v1.4.2)；对应 WebKit 源码按上游 `scripts/build/deps/webkit.ts` 的 `WEBKIT_VERSION` 获取，见 [oven-sh/WebKit](https://github.com/oven-sh/WebKit)。
