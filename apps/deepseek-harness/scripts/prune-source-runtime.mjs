#!/usr/bin/env node

import {
  readdirSync,
  rmdirSync,
  rmSync,
  statSync,
  unlinkSync,
} from 'node:fs'
import { join, relative, resolve } from 'node:path'

const [runtimeArgument] = process.argv.slice(2)
if (runtimeArgument === undefined) {
  throw new Error('usage: prune-source-runtime.mjs <runtime-root>')
}

const runtimeRoot = resolve(runtimeArgument)
const modulesRoot = join(runtimeRoot, 'node_modules')
if (!statSync(modulesRoot, { throwIfNoEntry: false })?.isDirectory()) {
  throw new Error(`node_modules directory is unavailable: ${modulesRoot}`)
}

const disposableDirectories = new Set([
  '.circleci',
  '.github',
  '.nyc_output',
  '.yarn',
  '__tests__',
  'benchmark',
  'benchmarks',
  'coverage',
  'doc',
  'docs',
  'example',
  'examples',
  'test',
  'tests',
])
// yaml ships executable modules below these directories; they are not documentation.
const runtimeDirectoriesToPreserve = new Set([
  'node_modules/yaml/dist/doc',
  'node_modules/yaml/browser/dist/doc',
])
const nodePtyPrebuildDirectory = /^node_modules\/node-pty\/prebuilds\/([^/]+)$/
const nativeSourceExtensions = new Set([
  '.asm',
  '.c',
  '.cc',
  '.cpp',
  '.gyp',
  '.gypi',
  '.h',
  '.hh',
  '.hpp',
  '.mk',
  '.s',
])
const documentationName = /^(?:authors|changelog|changes|code_of_conduct|contributing|history|readme|security)(?:\.(?:markdown|md|rst|txt))?$/i
const developmentConfigName = /^(?:\.editorconfig|\.eslintignore|\.eslintrc(?:\..*)?|\.npmignore|\.nvmrc|\.nycrc(?:\..*)?|\.prettierignore|\.prettierrc(?:\..*)?|eslint\.config\..*|jest\.config\..*|tsconfig(?:\..*)?\.json|typedoc\.json|vitest\.config\..*)$/i
const sourceTypeName = /\.(?:cts|mts|ts)$/i

function portablePath(path) {
  return relative(runtimeRoot, path).replaceAll('\\', '/')
}

function inventory(root) {
  const files = []
  let directories = 0
  let bytes = 0

  function visit(directory) {
    directories += 1
    const entries = readdirSync(directory, { withFileTypes: true }).sort((left, right) =>
      left.name.localeCompare(right.name),
    )
    for (const entry of entries) {
      const path = join(directory, entry.name)
      if (entry.isSymbolicLink()) throw new Error(`runtime contains a symbolic link: ${portablePath(path)}`)
      if (entry.isDirectory()) {
        visit(path)
        continue
      }
      if (!entry.isFile()) throw new Error(`runtime contains an unsupported entry: ${portablePath(path)}`)
      const stat = statSync(path)
      files.push({ path, size: stat.size })
      bytes += stat.size
    }
  }

  visit(root)
  return { bytes, directories, files }
}

const removed = new Map()
function recordRemoval(reason, path) {
  const stat = statSync(path)
  const current = removed.get(reason) ?? { bytes: 0, files: 0 }
  current.bytes += stat.size
  current.files += 1
  removed.set(reason, current)
  unlinkSync(path)
}

function removeTree(path, reason) {
  const tree = inventory(path)
  const current = removed.get(reason) ?? { bytes: 0, files: 0 }
  current.bytes += tree.bytes
  current.files += tree.files.length
  removed.set(reason, current)
  rmSync(path, { recursive: true })
}

function prune(directory) {
  const entries = readdirSync(directory, { withFileTypes: true }).sort((left, right) =>
    left.name.localeCompare(right.name),
  )
  for (const entry of entries) {
    const path = join(directory, entry.name)
    if (entry.isSymbolicLink()) throw new Error(`runtime contains a symbolic link: ${portablePath(path)}`)
    if (entry.isDirectory()) {
      const relativeDirectory = portablePath(path)
      const nodePtyPlatform = relativeDirectory.match(nodePtyPrebuildDirectory)?.[1]
      if (nodePtyPlatform !== undefined && nodePtyPlatform !== 'linux-x64') {
        removeTree(path, 'unsupported_platform_prebuilds')
      } else if (disposableDirectories.has(entry.name.toLowerCase()) && !runtimeDirectoriesToPreserve.has(relativeDirectory)) {
        removeTree(path, 'development_directories')
      } else {
        prune(path)
        if (readdirSync(path).length === 0) rmdirSync(path)
      }
      continue
    }
    if (!entry.isFile()) throw new Error(`runtime contains an unsupported entry: ${portablePath(path)}`)

    const lowerName = entry.name.toLowerCase()
    const extensionIndex = lowerName.lastIndexOf('.')
    const extension = extensionIndex === -1 ? '' : lowerName.slice(extensionIndex)
    if (lowerName.endsWith('.map')) recordRemoval('source_maps', path)
    else if (sourceTypeName.test(lowerName)) recordRemoval('typescript_sources', path)
    else if (documentationName.test(entry.name)) recordRemoval('documentation', path)
    else if (developmentConfigName.test(entry.name) || lowerName.endsWith('.tsbuildinfo')) {
      recordRemoval('development_config', path)
    } else if (nativeSourceExtensions.has(extension)) recordRemoval('native_sources', path)
  }
}

const before = inventory(runtimeRoot)
prune(modulesRoot)
const after = inventory(runtimeRoot)

const requiredPaths = [
  'node_modules/@deepseek-ai/dsh/lib/bin.js',
  'node_modules/@deepseek-ai/cordis-plugin-group/lib/index.js',
  'node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run',
  'node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/glibc/system.node',
  'node_modules/node-pty/prebuilds/linux-x64/pty.node',
  'node_modules/sharp/dist/index.cjs',
]
for (const requiredPath of requiredPaths) {
  const path = join(runtimeRoot, requiredPath)
  if (!statSync(path, { throwIfNoEntry: false })?.isFile()) {
    throw new Error(`runtime pruning removed a required path: ${requiredPath}`)
  }
}

process.stdout.write(
  `${JSON.stringify({
    after: { bytes: after.bytes, directories: after.directories, files: after.files.length },
    before: { bytes: before.bytes, directories: before.directories, files: before.files.length },
    removed: Object.fromEntries([...removed].sort(([left], [right]) => left.localeCompare(right))),
  })}\n`,
)
