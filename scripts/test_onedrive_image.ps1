#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'onedrive_image.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('onedrive-image-test-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temp)
$script:Passed = 0
function Assert-True([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:Passed++
}
function Assert-Rejected([scriptblock]$Operation, [string]$Label) {
    $rejected = $false
    try { $null = & $Operation } catch { $rejected = $true }
    Assert-True $rejected $Label
}
function New-TestResponse([int]$Status, [byte[]]$Bytes, [string]$Mime = 'image/png') {
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    $response.Content = [Net.Http.ByteArrayContent]::new($Bytes)
    if ($Mime) { $response.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new($Mime) }
    return $response
}
try {
    $png = Join-Path $temp 'probe.png'
    [IO.File]::WriteAllBytes($png, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
    $info = Get-ImageInfo $png
    Assert-True ($info.Kind -eq 'png' -and $info.Bytes -gt 12) 'PNG metadata'
    Assert-True ($info.RemoteName -eq "img-$($info.Sha256).png") 'content-addressed filename'
    $wrong = Join-Path $temp 'probe.jpg'
    Copy-Item -LiteralPath $png -Destination $wrong
    $rejected = $false
    try { $null = Get-ImageInfo $wrong } catch { $rejected = $true }
    Assert-True $rejected 'reject mismatched file signature'
    $short = Join-Path $temp 'short.png'
    [IO.File]::WriteAllBytes($short, [byte[]]@(1, 2, 3))
    $rejected = $false
    try { $null = Get-ImageInfo $short } catch { $rejected = $true }
    Assert-True $rejected 'reject truncated input'
    $secret = 'https://example.invalid/secret?signature=must-not-be-plain'
    $protected = Protect-DownloadUrl $secret
    Assert-True (-not $protected.Contains('must-not-be-plain')) 'DPAPI does not retain plaintext URL'
    $secure = ConvertTo-SecureString $protected
    $credential = [pscredential]::new('unused', $secure)
    Assert-True ($credential.GetNetworkCredential().Password -eq $secret) 'DPAPI round trip'
    $secure.Dispose()
    $receipt = [ordered]@{ schema = 1; state = 'ready'; appFolderId = 'app'; itemId = 'image'; sha256 = $info.Sha256;
        bytes = $info.Bytes; kind = $info.Kind; protectedDownloadUrl = $protected; urlVerifiedUtc = 'test' }
    $destination = Join-Path $temp 'receipts/probe.json'
    Save-Receipt $receipt $destination
    $loaded = Read-Receipt $destination
    Assert-True ($loaded['sha256'] -eq $info.Sha256) 'receipt round trip'
    $summary = Get-SafeReceiptSummary $loaded $destination | ConvertTo-Json -Compress
    Assert-True (-not $summary.Contains('protectedDownloadUrl') -and -not $summary.Contains('signature=')) 'safe stdout metadata'
    $invalid = [ordered]@{}
    foreach ($key in $receipt.Keys) { $invalid[$key] = $receipt[$key] }
    $invalid['sha256'] = 'not-a-hash'
    Save-Receipt $invalid $destination
    Assert-Rejected { Read-Receipt $destination } 'reject malformed hash even when byte count is integer'
    $invalid['sha256'] = $info.Sha256
    $invalid['bytes'] = [string]$info.Bytes
    Save-Receipt $invalid $destination
    Assert-Rejected { Read-Receipt $destination } 'reject non-numeric receipt size'
    $invalid['bytes'] = 250000001
    Save-Receipt $invalid $destination
    Assert-Rejected { Read-Receipt $destination } 'reject oversized receipt'
    Save-Receipt $receipt $destination
    Assert-Rejected { Get-SafeImageUri 'http://example.invalid/image.png' } 'reject HTTP download URL'
    Assert-Rejected { Get-SafeImageUri 'https://user:pass@example.invalid/image.png' } 'reject embedded URL credentials'
    Assert-Rejected { Get-SafeImageUri '/relative/image.png' } 'reject relative URL'
    Assert-True ((Get-SafeImageUri 'https://example.invalid/image.png').Scheme -eq 'https') 'accept HTTPS URL'
    $imageBytes = [IO.File]::ReadAllBytes($png)
    $response = New-TestResponse 200 $imageBytes
    try {
        $mime = Test-ImageResponse $response 'png' $info.Bytes ([Threading.CancellationToken]::None)
        Assert-True ($mime -eq 'image/png') 'accept verified 200 image response'
        Assert-Rejected { Test-ImageResponse $response 'png' ($info.Bytes + 1) ([Threading.CancellationToken]::None) } 'reject incorrect content length'
    } finally { $response.Dispose() }
    $response = New-TestResponse 206 $imageBytes
    try {
        $response.Content.Headers.ContentRange = [Net.Http.Headers.ContentRangeHeaderValue]::new(0, ($info.Bytes - 1), $info.Bytes)
        $mime = Test-ImageResponse $response 'png' $info.Bytes ([Threading.CancellationToken]::None)
        Assert-True ($mime -eq 'image/png') 'accept verified 206 image response'
        Assert-Rejected { Test-ImageResponse $response 'png' ($info.Bytes + 1) ([Threading.CancellationToken]::None) } 'reject incorrect Content-Range total'
    } finally { $response.Dispose() }
    $response = New-TestResponse 404 $imageBytes
    try { Assert-Rejected { Test-ImageResponse $response 'png' $info.Bytes ([Threading.CancellationToken]::None) } 'reject failed HTTP status' } finally { $response.Dispose() }
    $response = New-TestResponse 200 $imageBytes 'text/html'
    try { Assert-Rejected { Test-ImageResponse $response 'png' $info.Bytes ([Threading.CancellationToken]::None) } 'reject non-image MIME' } finally { $response.Dispose() }
    $response = New-TestResponse 200 ([byte[]]::new($info.Bytes))
    try { Assert-Rejected { Test-ImageResponse $response 'png' $info.Bytes ([Threading.CancellationToken]::None) } 'reject remote image signature mismatch' } finally { $response.Dispose() }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType)
        return @{ id = 'image'; parentReference = @{ id = $script:MockParent }; name = $info.RemoteName; size = $info.Bytes }
    }
    $script:MockParent = 'app'
    $null = Assert-OwnedItem $loaded @{ id = 'app' }
    Assert-True $true 'accept matching app-folder item'
    $script:MockParent = 'outside'
    $rejected = $false
    try { $null = Assert-OwnedItem $loaded @{ id = 'app' } } catch { $rejected = $true }
    Assert-True $rejected 'reject item moved outside app folder'
    $rejected = $false
    try { $null = Assert-OwnedItem $loaded @{ id = 'different-account' } } catch { $rejected = $true }
    Assert-True $rejected 'reject receipt from another account'
    [ordered]@{ status = 'passed'; assertions = $script:Passed; liveUploadTested = $false } | ConvertTo-Json -Compress
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    $expectedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedTemp)).StartsWith('onedrive-image-test-')) { throw 'Unsafe test cleanup path.' }
    foreach ($file in [IO.Directory]::GetFiles($temp, '*', [IO.SearchOption]::AllDirectories)) { [IO.File]::Delete($file) }
    foreach ($directory in ([IO.Directory]::GetDirectories($temp) | Sort-Object Length -Descending)) { [IO.Directory]::Delete($directory) }
    [IO.Directory]::Delete($temp)
}
