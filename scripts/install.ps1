#requires -Version 7.2
[CmdletBinding()]
param([string]$PythonExecutable = 'python')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows is required for DPAPI-protected credentials.' }
$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root '.venv'
$python = Join-Path $venv 'Scripts/python.exe'
& $PythonExecutable -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.11 or newer first.' }
if (-not (Test-Path -LiteralPath $venv)) {
    & $PythonExecutable -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the virtual environment.' }
}
if (-not (Test-Path -LiteralPath $python)) { throw 'Existing .venv is not a Windows Python environment; inspect it manually.' }
& $python -m pip install --disable-pip-version-check -r (Join-Path $root 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Python dependency installation failed.' }
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication | Where-Object Version -GE ([version]'2.41.2'))) {
    Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.41.2 -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
}
[ordered]@{ status = 'installed'; python = $python; authenticated = $false; nextAction = 'Connect, then Verify' } | ConvertTo-Json -Compress
