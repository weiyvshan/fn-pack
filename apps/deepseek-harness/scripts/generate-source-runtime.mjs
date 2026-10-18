#!/usr/bin/env node

import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative, resolve } from 'node:path'

const [sourceArgument, outputArgument, mode] = process.argv.slice(2)
if (
  sourceArgument === undefined ||
  outputArgument === undefined ||
  (mode !== undefined && mode !== '--manifest-only')
) {
  throw new Error(
    'usage: generate-source-runtime.mjs <source-root> <output-directory> [--manifest-only]',
  )
}

const sourceRoot = resolve(sourceArgument)
const outputDirectory = resolve(outputArgument)
const manifestOnly = mode === '--manifest-only'
const manifests = new Map()

function toPortablePath(path) {
  return path.replaceAll('\\', '/')
}

function visit(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === 'node_modules' || entry.name === '.fnos-runtime') continue
    const path = join(directory, entry.name)
    if (entry.isDirectory()) {
      visit(path)
      continue
    }
    if (entry.name !== 'package.json') continue
    const manifest = JSON.parse(readFileSync(path, 'utf8'))
    if (typeof manifest.name !== 'string') continue
    if (manifests.has(manifest.name)) throw new Error(`duplicate workspace package: ${manifest.name}`)
    const manifestDirectory = dirname(path)
    manifests.set(manifest.name, {
      directory: manifestDirectory,
      importerPath: toPortablePath(relative(sourceRoot, manifestDirectory)) || '.',
      manifest,
    })
  }
}

visit(sourceRoot)

const entryPackage = '@deepseek-ai/dsh'
if (!manifests.has(entryPackage)) throw new Error(`missing source entry package: ${entryPackage}`)

const queue = [entryPackage]
const closure = new Set()
while (queue.length > 0) {
  const name = queue.shift()
  if (closure.has(name)) continue
  closure.add(name)

  const record = manifests.get(name)
  if (record === undefined) continue
  const { manifest } = record
  for (const dependency of Object.keys(manifest.dependencies ?? {})) {
    if (manifests.has(dependency)) queue.push(dependency)
  }
  for (const peer of Object.keys(manifest.peerDependencies ?? {})) {
    if (manifest.peerDependenciesMeta?.[peer]?.optional === true) continue
    if (manifests.has(peer)) queue.push(peer)
  }
}

const packageNames = [...closure].sort()
const externalPeers = new Map()
for (const packageName of packageNames) {
  const { manifest } = manifests.get(packageName)
  for (const [peerName, peerRange] of Object.entries(manifest.peerDependencies ?? {})) {
    if (manifest.peerDependenciesMeta?.[peerName]?.optional === true || manifests.has(peerName)) continue
    if (typeof peerRange !== 'string') throw new Error(`invalid peer range: ${packageName} -> ${peerName}`)
    const existing = externalPeers.get(peerName)
    if (existing !== undefined && existing.range !== peerRange) {
      throw new Error(
        `incompatible external peer ranges for ${peerName}: ${existing.range} and ${peerRange}`,
      )
    }
    if (existing === undefined) externalPeers.set(peerName, { consumers: [], range: peerRange })
    externalPeers.get(peerName).consumers.push(packageName)
  }
}

const sourceManifest = JSON.parse(readFileSync(join(sourceRoot, 'package.json'), 'utf8'))
const dependencyEntries = [
  ...packageNames.map(name => [name, 'workspace:*']),
  ...[...externalPeers].map(([name, peer]) => [name, peer.range]),
].sort(([left], [right]) => left.localeCompare(right))
const runtimeManifest = {
  name: 'dsh-fnos-runtime',
  version: '0.0.0',
  private: true,
  packageManager: sourceManifest.packageManager,
  engines: sourceManifest.engines,
  dependencies: Object.fromEntries(dependencyEntries),
}

mkdirSync(outputDirectory, { recursive: true })
writeFileSync(join(outputDirectory, 'package.json'), `${JSON.stringify(runtimeManifest, null, 2)}\n`)

const workspacePath = join(sourceRoot, 'pnpm-workspace.yaml')
const workspaceText = readFileSync(workspacePath, 'utf8')
if (!workspaceText.startsWith('packages:\n')) throw new Error('pnpm-workspace.yaml has an unexpected packages header')
if (workspaceText.includes('\n  - .fnos-runtime\n')) throw new Error('pnpm-workspace.yaml already contains .fnos-runtime')
writeFileSync(workspacePath, workspaceText.replace('packages:\n', 'packages:\n  - .fnos-runtime\n'))

if (!manifestOnly) {
  const lockfilePath = join(sourceRoot, 'pnpm-lock.yaml')
  const sourceRequire = createRequire(join(sourceRoot, 'package.json'))
  const yaml = sourceRequire('yaml')
  const lockfile = yaml.parse(readFileSync(lockfilePath, 'utf8'))
  if (lockfile?.lockfileVersion !== '9.0' || typeof lockfile.importers !== 'object') {
    throw new Error('pnpm-lock.yaml has an unsupported structure')
  }

  const runtimeImporterPath = toPortablePath(relative(sourceRoot, outputDirectory))
  if (runtimeImporterPath === '' || runtimeImporterPath.startsWith('../')) {
    throw new Error('runtime output must be inside the source workspace')
  }
  if (lockfile.importers[runtimeImporterPath] !== undefined) {
    throw new Error(`pnpm-lock.yaml already contains ${runtimeImporterPath}`)
  }

  const lockedExternalPeers = new Map()
  for (const [peerName, peer] of externalPeers) {
    const lockedVersions = new Set()
    for (const consumerName of peer.consumers) {
      const consumer = manifests.get(consumerName)
      const importer = lockfile.importers[consumer.importerPath]
      if (importer === undefined) throw new Error(`lock importer missing: ${consumer.importerPath}`)
      for (const dependencyKind of ['dependencies', 'devDependencies', 'optionalDependencies']) {
        const lockedDependency = importer[dependencyKind]?.[peerName]
        if (typeof lockedDependency?.version === 'string') lockedVersions.add(lockedDependency.version)
      }
    }
    if (lockedVersions.size !== 1) {
      throw new Error(
        `external peer ${peerName} must have one existing locked version, got ${[
          ...lockedVersions,
        ].join(', ')}`,
      )
    }
    lockedExternalPeers.set(peerName, [...lockedVersions][0])
  }

  lockfile.importers[runtimeImporterPath] = {
    dependencies: Object.fromEntries(
      dependencyEntries.map(([name, specifier]) => {
        const workspacePackage = manifests.get(name)
        if (workspacePackage === undefined) {
          return [name, { specifier, version: lockedExternalPeers.get(name) }]
        }

        const linkedVersion = `link:${toPortablePath(
          relative(outputDirectory, workspacePackage.directory),
        )}`
        const override = lockfile.overrides?.[name]
        if (typeof override === 'string' && override.startsWith('link:')) {
          const overrideTarget = resolve(sourceRoot, override.slice('link:'.length))
          if (overrideTarget !== workspacePackage.directory) {
            throw new Error(`workspace override target mismatch for ${name}: ${override}`)
          }
          return [name, { specifier: linkedVersion, version: linkedVersion }]
        }
        return [name, { specifier, version: linkedVersion }]
      }),
    ),
  }
  writeFileSync(lockfilePath, yaml.stringify(lockfile, { lineWidth: 0 }))
}

const dshVersion = manifests.get(entryPackage).manifest.version
if (typeof dshVersion !== 'string') throw new Error(`${entryPackage} has no version`)
process.stdout.write(
  `${JSON.stringify({
    dshVersion,
    externalPeers: externalPeers.size,
    workspacePackages: packageNames.length,
  })}\n`,
)
