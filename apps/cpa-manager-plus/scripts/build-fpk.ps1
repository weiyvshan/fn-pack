[CmdletBinding()]
param(
  [string]$RepairFpkPath
)

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($RepairFpkPath)) {
  throw 'In-place FPK permission repair is retired; rebuild from the locked release binaries with build-fpk.sh.'
}

$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$scriptPath = Join-Path $project 'scripts\build-fpk.sh'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "Authoritative Linux build script is missing: $scriptPath"
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
& $shell -lc 'exec bash "$1"' bash (Convert-ToShellPath $scriptPath)
if ($LASTEXITCODE -ne 0) {
  throw "Authoritative Linux FPK build failed with exit code $LASTEXITCODE"
}
