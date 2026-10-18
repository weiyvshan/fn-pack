# Third-party notices

This fnOS integration packages `@deepseek-ai/dsh` 0.2.1-rc.2 from the locked
DeepSeek `deepseek-harness` Git source. DeepSeek Harness is distributed under
the MIT License; its package and transitive dependency license files remain in
the bundled runtime tree.

The Linux x86-64 runtime is built directly from official commit
`687f282e8625c6b8d11ff58211a90524be2e4317`. The Git tree, source lockfile,
CLI manifest, and target identity are recorded in `runtime.lock.json`; no
third-party fnOS FPK contributes runtime files.

Four local, hash-locked source patches are applied in order to the fixed
official commit. They add fnOS profile-local pnpm-store integration to the
upstream plugin manager, private Web authentication-token handoff, attachment
persistence across restricted volume ancestors, and a bounded TypeScript build
heap; no patch imports files from another FPK.

This integration also packages `pnpm` 11.28.5 under the MIT License so the
upstream `dsh plugin` command works without a NAS-global package-manager
installation. Its public npm tarball identity and integrity are recorded in
`runtime.lock.json`, and its license remains in the bundled `pnpm` directory.

The official `@deepseek-ai/node-addon-system-linux-x64` 0.1.2 binaries (static
Landlock launcher and glibc/musl flock Node-API addons) are overlaid into the
runtime and verified against their public npm identity in `runtime.lock.json`.

The gateway serves a minified browser bundle of `@trimjs/web-app` 0.4.2 (the
fnOS JS SDK) at `/__fnos/trim-web-app.js` for presented-file `openFile` and
workspace `openFileManager` page routing. Its npm provenance, build recipe,
and artifact hash are recorded in `app/web/trim-web-app.lock.json`, and its
license remains available in the upstream npm package.

Gateway and lifecycle behavior was independently adapted from community fnOS
implementations and hardened against the fnOS platform contract. Those
projects are design evidence only and are not build inputs. See `README.md`
for provenance and validation boundaries.
