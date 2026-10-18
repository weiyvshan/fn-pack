import assert from 'node:assert/strict'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const pruner = join(projectRoot, 'scripts', 'prune-source-runtime.mjs')
const temporaryRoot = mkdtempSync(join(tmpdir(), 'dsh-fnos-prune-test-'))
const runtimeRoot = join(temporaryRoot, 'runtime')

function write(relativePath, content = relativePath) {
  const path = join(runtimeRoot, relativePath)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
  return path
}

try {
  const requiredPaths = [
    'node_modules/@deepseek-ai/dsh/lib/bin.js',
    'node_modules/@deepseek-ai/cordis-plugin-group/lib/index.js',
    'node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run',
    'node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/glibc/system.node',
    'node_modules/node-pty/prebuilds/linux-x64/pty.node',
    'node_modules/sharp/dist/index.cjs',
  ]
  for (const path of requiredPaths) write(path, `required:${path}`)

  const firstDuplicate = write('node_modules/fixture/dist/first.js', 'same-runtime-content\n')
  const secondDuplicate = write('node_modules/fixture/dist/second.js', 'same-runtime-content\n')
  write('node_modules/fixture/package.json', '{"name":"fixture"}\n')
  write('node_modules/fixture/LICENSE', 'retain license\n')
  write('node_modules/fixture/dist/config.json', '{"enabled":true}\n')
  write('node_modules/fixture/dist/module.wasm', 'runtime wasm\n')
  write('node_modules/fixture/dist/security.js', 'export const secure = true\n')
  write('node_modules/fixture/dist/index.js.map', '{}\n')
  write('node_modules/fixture/dist/index.d.ts', 'export declare const value: string\n')
  write('node_modules/fixture/src/index.ts', 'export const value: string = "source"\n')
  write('node_modules/fixture/README.md', 'development docs\n')
  write('node_modules/fixture/tsconfig.json', '{}\n')
  write('node_modules/fixture/native/addon.cc', 'native build source\n')
  write('node_modules/fixture/test/fixture.json', '{}\n')
  write('node_modules/fixture/doc/guide.md', 'development docs\n')
  write('node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper', 'darwin arm64 helper\n')
  write('node_modules/node-pty/prebuilds/darwin-x64/spawn-helper', 'darwin x64 helper\n')
  write('node_modules/yaml/dist/doc/directives.js', 'export const directives = true\n')
  write('outside-node-modules.ts', 'retain application-owned source\n')

  const result = spawnSync(process.execPath, [pruner, runtimeRoot], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  const report = JSON.parse(result.stdout)

  assert.equal(report.before.files, 25)
  assert.equal(report.after.files, 15)
  assert.equal(report.removed.source_maps.files, 1)
  assert.equal(report.removed.typescript_sources.files, 2)
  assert.equal(report.removed.documentation.files, 1)
  assert.equal(report.removed.development_config.files, 1)
  assert.equal(report.removed.native_sources.files, 1)
  assert.equal(report.removed.development_directories.files, 2)
  assert.equal(report.removed.unsupported_platform_prebuilds.files, 2)

  for (const path of requiredPaths) assert.equal(existsSync(join(runtimeRoot, path)), true)
  assert.equal(readFileSync(join(runtimeRoot, 'node_modules/fixture/LICENSE'), 'utf8'), 'retain license\n')
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/dist/config.json')), true)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/dist/module.wasm')), true)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/dist/security.js')), true)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/dist/index.js.map')), false)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/src')), false)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/test')), false)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/fixture/doc')), false)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/node-pty/prebuilds/darwin-arm64')), false)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/node-pty/prebuilds/darwin-x64')), false)
  assert.equal(existsSync(join(runtimeRoot, 'node_modules/yaml/dist/doc/directives.js')), true)
  assert.equal(existsSync(join(runtimeRoot, 'outside-node-modules.ts')), true)
  assert.equal(readFileSync(firstDuplicate, 'utf8'), readFileSync(secondDuplicate, 'utf8'))
  process.stdout.write('prune-source-runtime tests passed\n')
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true })
}
