#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'onedrive_image.ps1'
$root = Join-Path $env:LOCALAPPDATA 'Codex/onedrive-image-upload'
if ($env:ONEDRIVE_IMAGE_CLIENT_ID) {
    $clientId = [guid]::Parse($env:ONEDRIVE_IMAGE_CLIENT_ID).ToString()
    if ($clientId -ne '14d82eec-204b-4c2f-b7e8-296a70dab67e') { $root = Join-Path $root "clients/$clientId" }
}
$probeId = [Guid]::NewGuid().ToString('N')
$probe = Join-Path $root "probes/$probeId.png"
$testReceiptPath = Join-Path $root "receipts/probe-$probeId.json"
$stage = 'create_fixture'
$uploaded = $false
$removed = $false
$verified = $false

# Each operation runs in a new process to exercise persisted login and renewal.
function Invoke-Helper {
    param([string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new('pwsh.exe')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in (@('-NoProfile', '-File', $helper) + $Arguments)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill($true)
            throw 'Helper exceeded the test timeout.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Helper failed; raw output suppressed.' }
        return ($stdout | ConvertFrom-Json -AsHashtable)
    } finally { $process.Dispose() }
}

$report = [ordered]@{ status = 'failed'; liveUploadTested = $false; anonymousContentVerified = $false;
    crossProcessLoginVerified = $false; remoteFileRemoved = $false; receiptPath = $testReceiptPath }
try {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $probe))
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new(32, 32)
    try {
        for ($x = 0; $x -lt 32; $x++) {
            for ($y = 0; $y -lt 32; $y++) {
                $bitmap.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, ($x * 8), ($y * 8), 96))
            }
        }
        $marker = [Guid]::NewGuid().ToByteArray()
        for ($x = 0; $x -lt 16; $x++) { $bitmap.SetPixel($x, 0, [Drawing.Color]::FromArgb(255, $marker[$x], 17, 219)) }
        $bitmap.Save($probe, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    $stage = 'upload'
    $result = Invoke-Helper @('-Action', 'Upload', '-Path', $probe, '-ReceiptPath', $testReceiptPath)
    $uploaded = $result['status'] -eq 'ready'
    if (-not $uploaded) { throw 'Upload not ready.' }
    $report['liveUploadTested'] = $true
    $stage = 'refresh_in_new_process'
    $result = Invoke-Helper @('-Action', 'Refresh', '-ReceiptPath', $testReceiptPath)
    if ($result['status'] -ne 'ready') { throw 'Refresh not ready.' }
    $report['crossProcessLoginVerified'] = $true
    $stage = 'anonymous_full_content_check'
    $result = Invoke-Helper @('-Action', 'Url', '-ReceiptPath', $testReceiptPath, '-RevealUrl')
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $response = $client.GetAsync($result['url'], [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            $null = $response.EnsureSuccessStatusCode()
            $bytes = (Get-Item -LiteralPath $probe).Length
            if ($response.Content.Headers.ContentLength -ne $bytes -or $bytes -gt 65536) { throw 'Unexpected test response size.' }
            $downloaded = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($downloaded)).ToLowerInvariant()
            $verified = $hash -eq (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not $verified) { throw 'Round-trip image hash mismatch.' }
            $report['anonymousContentVerified'] = $true
            $report['bytes'] = $bytes
        } finally { $response.Dispose() }
    } finally { $client.Dispose(); $result = $null }
    $stage = 'remove_test_file'
    $result = Invoke-Helper @('-Action', 'Remove', '-ReceiptPath', $testReceiptPath)
    $removed = $result['status'] -eq 'removed'
    if (-not $removed) { throw 'Remote cleanup failed.' }
    $stage = 'confirm_remote_absence'
    . $helper
    Import-Graph
    Assert-GraphContext
    $receipt = Read-Receipt $testReceiptPath
    $null = Invoke-MgGraphRequest -Method GET -Uri (Get-ItemUri $receipt['itemId']) -OutputType Hashtable -SkipHttpErrorCheck -StatusCodeVariable absenceStatus
    if ([int]$absenceStatus -ne 404) { throw 'Remote test file absence was not confirmed.' }
    $report['remoteFileRemoved'] = $true
    $report['status'] = 'passed'
} catch {
    $report['failedStage'] = $stage
    $report['errorType'] = $_.Exception.GetType().Name
} finally {
    if (-not $removed -and (Test-Path -LiteralPath $testReceiptPath)) {
        try {
            $receipt = Get-Content -LiteralPath $testReceiptPath -Raw | ConvertFrom-Json -AsHashtable
            if ($receipt['itemId']) {
                $cleanup = Invoke-Helper @('-Action', 'Remove', '-ReceiptPath', $testReceiptPath)
                $report['remoteFileRemoved'] = $cleanup['status'] -eq 'removed'
            }
        } catch { $report['cleanupFailed'] = $true }
    }
    if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) }
}
Save-Receipt $report (Join-Path $root 'live-verification.json')
$report | ConvertTo-Json -Compress
if ($report['status'] -ne 'passed') { exit 1 }
