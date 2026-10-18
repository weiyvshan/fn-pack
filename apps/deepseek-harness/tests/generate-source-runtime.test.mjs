import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const generator = join(projectRoot, 'scripts', 'generate-source-runtime.mjs')
const temporaryRoot = mkdtempSync(join(tmpdir(), 'dsh-fnos-runtime-test-'))

function writeManifest(relativePath, manifest) {
  const path = join(temporaryRoot, relativePath, 'package.json')
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`)
}

try {
  writeManifest('.', {
    name: 'fixture-root',
    version: '1.0.0',
    private: true,
    packageManager: 'pnpm@11.7.0',
    engines: { node: '>=22.19.0' },
  })
  writeFileSync(join(temporaryRoot, 'pnpm-workspace.yaml'), 'packages:\n  - packages/*\n')
  writeManifest('packages/cli', {
    name: '@deepseek-ai/dsh',
    version: '1.2.3',
    dependencies: { '@fixture/alpha': 'workspace:*' },
    peerDependencies: { '@fixture/group': 'workspace:*' },
  })
  writeManifest('packages/alpha', {
    name: '@fixture/alpha',
    version: '1.0.0',
    peerDependencies: {
      '@fixture/schema': 'workspace:*',
      '@fixture/optional': 'workspace:*',
      react: '^18.2.0',
    },
    peerDependenciesMeta: { '@fixture/optional': { optional: true } },
  })
  writeManifest('packages/group', {
    name: '@fixture/group',
    version: '1.0.0',
    dependencies: { '@fixture/schema': 'workspace:*' },
  })
  writeManifest('packages/schema', { name: '@fixture/schema', version: '1.0.0' })
  writeManifest('packages/optional', { name: '@fixture/optional', version: '1.0.0' })
  writeManifest('packages/unrelated', { name: '@fixture/unrelated', version: '1.0.0' })

  const output = join(temporaryRoot, '.fnos-runtime')
  const result = spawnSync(process.execPath, [generator, temporaryRoot, output, '--manifest-only'], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), {
    dshVersion: '1.2.3',
    externalPeers: 1,
    workspacePackages: 4,
  })

  const runtime = JSON.parse(readFileSync(join(output, 'package.json'), 'utf8'))
  assert.deepEqual(Object.keys(runtime.dependencies), [
    '@deepseek-ai/dsh',
    '@fixture/alpha',
    '@fixture/group',
    '@fixture/schema',
    'react',
  ])
  assert.equal(runtime.dependencies.react, '^18.2.0')
  assert.equal(runtime.dependencies['@fixture/optional'], undefined)
  assert.equal(runtime.dependencies['@fixture/unrelated'], undefined)
  assert.match(readFileSync(join(temporaryRoot, 'pnpm-workspace.yaml'), 'utf8'), /^packages:\n  - \.fnos-runtime\n/)
  process.stdout.write('generate-source-runtime tests passed\n')
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true })
}
