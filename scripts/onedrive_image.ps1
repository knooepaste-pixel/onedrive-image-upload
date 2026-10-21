#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Connect', 'Verify', 'Upload', 'Refresh', 'Url', 'Remove')]
    [string]$Action = 'Status',
    [string]$Path,
    [string]$ReceiptPath,
    [switch]$RevealUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This tool requires Windows DPAPI and PowerShell 7.2 or newer.' }
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
$script:StorageRoot = Join-Path $env:LOCALAPPDATA 'Codex/onedrive-image-upload'
if ($env:ONEDRIVE_IMAGE_CLIENT_ID) {
    $clientId = [guid]::Parse($env:ONEDRIVE_IMAGE_CLIENT_ID).ToString()
    if ($clientId -ne '14d82eec-204b-4c2f-b7e8-296a70dab67e') {
        $script:StorageRoot = Join-Path $script:StorageRoot "clients/$clientId"
    }
}
$script:RequiredScope = 'Files.ReadWrite.AppFolder'
$script:AuthHelper = Join-Path $PSScriptRoot 'onedrive_auth.py'

function Get-ImageInfo {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $file = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -lt 12 -or $file.Length -gt 250000000) {
        throw 'Input must be an image file of 12 to 250000000 bytes.'
    }
    $bytes = [byte[]]::new(12)
    $stream = [IO.File]::OpenRead($file.FullName)
    try { $null = $stream.Read($bytes, 0, 12) } finally { $stream.Dispose() }
    $kind = Get-ImageKind $bytes
    $types = @{ png = 'image/png'; jpg = 'image/jpeg'; webp = 'image/webp'; gif = 'image/gif' }
    if (-not $types.ContainsKey($kind)) { throw 'Only real PNG, JPEG, WebP and GIF inputs are supported.' }
    $extensions = @{ '.png' = 'png'; '.jpg' = 'jpg'; '.jpeg' = 'jpg'; '.webp' = 'webp'; '.gif' = 'gif' }
    if (-not $extensions.ContainsKey($file.Extension.ToLowerInvariant()) -or
        $extensions[$file.Extension.ToLowerInvariant()] -ne $kind) {
        throw 'Image extension does not match its signature.'
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject]@{ Path = $file.FullName; Bytes = $file.Length; Sha256 = $hash;
        Kind = $kind; ContentType = $types[$kind]; RemoteName = "img-$hash.$kind" }
}

function Get-ImageKind {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 8 -and [Convert]::ToHexString($Bytes[0..7]) -eq '89504E470D0A1A0A') { return 'png' }
    if ($Bytes.Length -ge 3 -and [Convert]::ToHexString($Bytes[0..2]) -eq 'FFD8FF') { return 'jpg' }
    if ($Bytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -eq 'RIFF' -and
        [Text.Encoding]::ASCII.GetString($Bytes, 8, 4) -eq 'WEBP') { return 'webp' }
    if ($Bytes.Length -ge 6 -and [Text.Encoding]::ASCII.GetString($Bytes, 0, 6) -in @('GIF87a', 'GIF89a')) { return 'gif' }
    return 'unknown'
}

function Import-Graph {
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.41.2 -ErrorAction Stop
}

function Get-PythonExecutable {
    if ($env:ONEDRIVE_IMAGE_PYTHON) {
        if (-not [IO.File]::Exists($env:ONEDRIVE_IMAGE_PYTHON)) { throw 'Configured Python executable does not exist.' }
        return $env:ONEDRIVE_IMAGE_PYTHON
    }
    $venv = Join-Path (Split-Path -Parent $PSScriptRoot) '.venv/Scripts/python.exe'
    if ([IO.File]::Exists($venv)) { return $venv }
    return (Get-Command python -CommandType Application -ErrorAction Stop).Source
}

function Invoke-AuthHelper {
    param([ValidateSet('status', 'connect', 'token')][string]$Operation)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-PythonExecutable))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add($script:AuthHelper)
    $start.ArgumentList.Add($Operation)
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            $process.Kill($true)
            throw 'Authorization helper timed out; raw output suppressed.'
        }
        $raw = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Authorization helper failed; run Connect or check installation.' }
        return ($raw | ConvertFrom-Json -AsHashtable)
    } finally { $process.Dispose() }
}

function Assert-GraphContext {
    $auth = Invoke-AuthHelper token
    if ($auth['status'] -ne 'authorized' -or -not $auth['personalAccount'] -or
        $auth['scope'] -ne $script:RequiredScope -or -not $auth['access_token']) {
        throw 'OneDrive authorization is missing. Run -Action Connect and complete Microsoft sign-in.'
    }
    $secure = ConvertTo-SecureString $auth['access_token'] -AsPlainText -Force
    $auth.Remove('access_token')
    try { Connect-MgGraph -AccessToken $secure -NoWelcome | Out-Null } finally { $secure.Dispose() }
}

function Get-AppRoot {
    $root = Invoke-MgGraphRequest -Method GET -Uri "$script:GraphRoot/me/drive/special/approot" -OutputType Hashtable
    if (-not $root['id'] -or -not $root.ContainsKey('folder')) { throw 'Microsoft did not return an application folder.' }
    return $root
}

function Get-ItemUri {
    param([string]$Id)
    return "$script:GraphRoot/me/drive/items/$([Uri]::EscapeDataString($Id))"
}

function Get-SafeImageUri {
    param([string]$Url)
    $uri = [uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Image download URL must use HTTPS.' }
    return $uri
}

function Test-ImageResponse {
    param([Net.Http.HttpResponseMessage]$Response, [string]$Kind, [long]$ExpectedBytes, [Threading.CancellationToken]$CancellationToken)
    $status = [int]$Response.StatusCode
    if ($status -notin @(200, 206)) { throw "Image URL GET failed with HTTP $status." }
    $mime = $Response.Content.Headers.ContentType.MediaType
    if (-not $mime -or -not $mime.StartsWith('image/', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Download URL did not return image content.'
    }
    $range = $Response.Content.Headers.ContentRange
    if ($status -eq 206 -and ($null -eq $range -or $range.From -ne 0 -or $range.Length -ne $ExpectedBytes)) {
        throw 'Image URL range does not match uploaded file size.'
    }
    if ($status -eq 200 -and $Response.Content.Headers.ContentLength -ne $ExpectedBytes) {
        throw 'Image URL content length does not match uploaded file size.'
    }
    $body = $Response.Content.ReadAsStream()
    try {
        $prefix = [byte[]]::new(12)
        $count = 0
        while ($count -lt 12) {
            $read = $body.ReadAsync($prefix, $count, 12 - $count, $CancellationToken).GetAwaiter().GetResult()
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -ne 12 -or (Get-ImageKind $prefix) -ne $Kind) { throw 'Remote image signature mismatch.' }
    } finally { $body.Dispose() }
    return $mime
}

function Test-ImageUrl {
    param([string]$Url, [string]$Kind, [long]$ExpectedBytes)
    $uri = Get-SafeImageUri $Url
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    try {
        for ($hop = 0; $hop -le 5; $hop++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $uri)
            $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new(0, 511)
            $response = $null
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if (-not $response.Headers.Location) { throw 'Image redirect has no destination.' }
                    $next = [uri]::new($uri, $response.Headers.Location)
                    $uri = Get-SafeImageUri $next.AbsoluteUri
                    continue
                }
                $mime = Test-ImageResponse $response $Kind $ExpectedBytes $deadline.Token
                return [pscustomobject]@{ Status = $status; ContentType = $mime; Redirects = $hop; VerifiedUtc = [DateTime]::UtcNow.ToString('o') }
            } finally {
                if ($response) { $response.Dispose() }
                $request.Dispose()
            }
        }
        throw 'Too many image URL redirects.'
    } finally { $client.Dispose(); $deadline.Dispose() }
}

function Protect-DownloadUrl {
    param([string]$Url)
    $secure = ConvertTo-SecureString -String $Url -AsPlainText -Force
    try { return ConvertFrom-SecureString -SecureString $secure } finally { $secure.Dispose() }
}

function Save-Receipt {
    param([System.Collections.IDictionary]$Receipt, [string]$Destination)
    $directory = Split-Path -Parent $Destination
    $null = [IO.Directory]::CreateDirectory($directory)
    $temp = Join-Path $directory ('.receipt-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($Receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Destination, $true)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Read-Receipt {
    param([string]$LiteralPath)
    if (-not $LiteralPath) { throw 'ReceiptPath is required.' }
    $receipt = Get-Content -LiteralPath $LiteralPath -Raw | ConvertFrom-Json -AsHashtable
    if ($receipt['schema'] -ne 1 -or $receipt['sha256'] -notmatch '^[a-f0-9]{64}$' -or
        $receipt['kind'] -notin @('png', 'jpg', 'webp', 'gif') -or -not $receipt['itemId'] -or -not $receipt['appFolderId'] -or
        ($receipt['bytes'] -isnot [long] -and $receipt['bytes'] -isnot [int]) -or
        $receipt['bytes'] -lt 12 -or $receipt['bytes'] -gt 250000000) {
        throw 'Invalid image-upload receipt.'
    }
    return $receipt
}

function Assert-OwnedItem {
    param([System.Collections.IDictionary]$Receipt, [System.Collections.IDictionary]$Root)
    if ($Receipt['appFolderId'] -ne $Root['id']) { throw 'Receipt belongs to a different OneDrive app folder or account.' }
    $item = Invoke-MgGraphRequest -Method GET -Uri (Get-ItemUri $Receipt['itemId']) -OutputType Hashtable
    $expectedName = 'img-' + $Receipt['sha256'] + '.' + $Receipt['kind']
    if ($item['parentReference']['id'] -ne $Root['id'] -or $item['name'] -ne $expectedName -or
        $item['size'] -ne $Receipt['bytes']) { throw 'Remote item does not match the protected upload scope.' }
    return $item
}

function Update-ReceiptUrl {
    param([System.Collections.IDictionary]$Receipt, [System.Collections.IDictionary]$Item)
    $url = $Item['@microsoft.graph.downloadUrl']
    if (-not $url) { throw 'Microsoft did not return a temporary image download URL.' }
    $check = Test-ImageUrl -Url $url -Kind $Receipt['kind'] -ExpectedBytes $Receipt['bytes']
    $Receipt['protectedDownloadUrl'] = Protect-DownloadUrl $url
    $Receipt['urlVerifiedUtc'] = $check.VerifiedUtc
    $Receipt['urlHttpStatus'] = $check.Status
    $Receipt['urlContentType'] = $check.ContentType
    return $url
}

function Get-SafeReceiptSummary {
    param([System.Collections.IDictionary]$Receipt, [string]$Destination)
    return [ordered]@{ status = 'ready'; receiptPath = [IO.Path]::GetFullPath($Destination);
        itemId = $Receipt['itemId']; bytes = $Receipt['bytes']; sha256 = $Receipt['sha256'];
        urlVerifiedUtc = $Receipt['urlVerifiedUtc']; temporaryUrl = $true; permanentSharingCreated = $false }
}

function Invoke-OneDriveImage {
    param([string]$Operation, [string]$InputPath, [string]$ReceiptFile, [bool]$AllowUrl)
    if ($Operation -eq 'Status') {
        return (Invoke-AuthHelper status)
    }
    if ($Operation -eq 'Url' -and -not $AllowUrl) { throw 'Url mode requires -RevealUrl and privately captured stdout.' }
    if ($Operation -eq 'Connect') {
        $connection = Invoke-AuthHelper connect
        if ($connection['status'] -eq 'authorization_pending') { return $connection }
    }
    if ($Operation -eq 'Upload' -and -not $InputPath) { throw 'Path is required for Upload.' }
    $info = if ($Operation -eq 'Upload') { Get-ImageInfo $InputPath } else { $null }
    Import-Graph
    Assert-GraphContext
    $root = Get-AppRoot
    if ($Operation -in @('Connect', 'Verify')) {
        return [ordered]@{ status = 'connected_verified'; appFolderId = $root['id']; appFolderName = $root['name']; scope = $script:RequiredScope }
    }
    if ($Operation -eq 'Upload') {
        if (-not $ReceiptFile) { $ReceiptFile = Join-Path $script:StorageRoot "receipts/$($info.Sha256).json" }
        # Persist intent before upload so partial failures retain the remote filename for diagnosis.
        $receipt = [ordered]@{ schema = 1; state = 'uploading'; appFolderId = $root['id']; remoteName = $info.RemoteName;
            sha256 = $info.Sha256; kind = $info.Kind; bytes = $info.Bytes; createdUtc = [DateTime]::UtcNow.ToString('o') }
        Save-Receipt $receipt $ReceiptFile
        $uri = (Get-ItemUri $root['id']) + ':/' + $info.RemoteName + ':/content'
        $item = Invoke-MgGraphRequest -Method PUT -Uri $uri -InputFilePath $info.Path -ContentType $info.ContentType -OutputType Hashtable
        $receipt['itemId'] = $item['id']
        $receipt['state'] = 'uploaded_url_unverified'
        Save-Receipt $receipt $ReceiptFile
        $item = Assert-OwnedItem $receipt $root
    } else {
        $receipt = Read-Receipt $ReceiptFile
        $item = Assert-OwnedItem $receipt $root
    }
    if ($Operation -eq 'Remove') {
        Invoke-MgGraphRequest -Method DELETE -Uri (Get-ItemUri $receipt['itemId']) | Out-Null
        $receipt.Remove('protectedDownloadUrl') | Out-Null
        $receipt['state'] = 'removed'
        Save-Receipt $receipt $ReceiptFile
        return [ordered]@{ status = 'removed'; itemId = $receipt['itemId']; receiptPath = [IO.Path]::GetFullPath($ReceiptFile) }
    }
    $url = Update-ReceiptUrl $receipt $item
    $receipt['state'] = 'ready'
    Save-Receipt $receipt $ReceiptFile
    $summary = Get-SafeReceiptSummary $receipt $ReceiptFile
    if ($Operation -eq 'Url') { $summary['url'] = $url }
    return $summary
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-OneDriveImage -Operation $Action -InputPath $Path -ReceiptFile $ReceiptPath -AllowUrl ([bool]$RevealUrl)
        $result | ConvertTo-Json -Depth 6 -Compress
    } catch {
        # Raw SDK exceptions can contain signed URLs or authentication responses.
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        [ordered]@{ status = 'failed'; operation = $Action; httpStatus = $status; errorType = $_.Exception.GetType().Name;
            guidance = 'Check authorization with Connect/Verify, input signature/size and receipt account. No automatic paid request or public sharing was attempted.' } | ConvertTo-Json -Compress
        exit 1
    }
}
