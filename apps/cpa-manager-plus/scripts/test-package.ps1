[CmdletBinding()]
param(
  [string]$ProjectPath = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$scriptPath = Join-Path $project 'scripts\test-package.sh'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "POSIX package test is missing: $scriptPath"
}

function Resolve-Shell {
  if (-not $IsWindows) {
    return (Get-Command bash -ErrorAction Stop).Source
  }
  $gitPath = (Get-Command git -ErrorAction Stop).Source
  $gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
  $candidate = @(
    (Join-Path $gitRoot 'bin\sh.exe'),
    (Join-Path $gitRoot 'usr\bin\sh.exe'),
    (Join-Path (Split-Path -Parent $gitRoot) 'bin\sh.exe')
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($null -eq $candidate) { throw 'Git for Windows sh is required.' }
  return $candidate
}

function Convert-ToShellPath {
  param([string]$Path)
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $IsWindows) { return $resolved }
  $drive = $resolved.Substring(0, 1).ToLowerInvariant()
  return '/' + $drive + $resolved.Substring(2).Replace('\', '/')
}

$shell = Resolve-Shell
& $shell -lc 'exec sh "$1"' sh (Convert-ToShellPath $scriptPath)
if ($LASTEXITCODE -ne 0) {
  throw "POSIX package test failed with exit code $LASTEXITCODE"
}
