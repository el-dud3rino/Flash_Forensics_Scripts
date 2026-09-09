<#
.SYNOPSIS
    Flash Forensics - local AI proxy + static server (PowerShell, no Python required).

.DESCRIPTION
    Some AI gateways (notably GenAI.mil) do not send CORS headers, so a browser
    refuses to read their responses when the dashboard calls them directly. This
    script serves the dashboard AND relays its API calls server-to-server, where
    CORS does not apply. Everything stays on your machine; your API key travels
    from the browser to this local proxy to the gateway, exactly as it would
    directly - nothing is stored or logged here.

    This is the PowerShell twin of tools/ff-ai-proxy.py for systems without Python.

.EXAMPLE
    # From the repository root, in the same elevated PowerShell you run collection in:
    .\tools\ff-ai-proxy.ps1
    # then open http://localhost:8000/  (or /example/ for the sample) and tick
    # "Route through local proxy" in the dashboard's AI Settings.

.PARAMETER Port
    Port to listen on (default 8000).
.PARAMETER Dir
    Directory to serve (default: current directory).
.PARAMETER Insecure
    Skip TLS certificate validation for the upstream (only on TLS-inspected
    networks, and only if you understand the risk).
#>
param(
    [int]$Port = 8000,
    [string]$Dir = ".",
    [switch]$Insecure
)

$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
if ($Insecure) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    Write-Warning "Upstream TLS verification disabled (-Insecure)."
}

$Root = (Resolve-Path $Dir).Path
$ProxyPath = "/__ai_proxy"
# Request headers we relay to the upstream (auth + content type + Anthropic's browser flags).
$ForwardHeaders = @("Authorization", "x-api-key", "anthropic-version", "anthropic-dangerous-direct-browser-access")
$Mime = @{
    ".html"="text/html; charset=utf-8"; ".htm"="text/html; charset=utf-8"; ".js"="application/javascript; charset=utf-8";
    ".css"="text/css; charset=utf-8"; ".json"="application/json; charset=utf-8"; ".md"="text/markdown; charset=utf-8";
    ".csv"="text/csv; charset=utf-8"; ".txt"="text/plain; charset=utf-8"; ".png"="image/png"; ".jpg"="image/jpeg";
    ".jpeg"="image/jpeg"; ".gif"="image/gif"; ".svg"="image/svg+xml"; ".ico"="image/x-icon"; ".pdf"="application/pdf"
}

$Listener = New-Object System.Net.HttpListener
$Prefix = "http://localhost:$Port/"
$Listener.Prefixes.Add($Prefix)
try {
    $Listener.Start()
} catch {
    Write-Error ("Could not start listener on $Prefix. Run this in an ELEVATED PowerShell " +
                 "(the same one you use for collection), or use the Python proxy instead. Details: $($_.Exception.Message)")
    exit 1
}

Write-Host "Flash Forensics AI proxy serving $Root at $Prefix" -ForegroundColor Green
Write-Host "Open the dashboard there and enable 'Route through local proxy' in AI Settings."
Write-Host "Press Ctrl+C to stop."

function Write-Bytes($Response, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $Response.StatusCode = $Status
    if ($ContentType) { $Response.ContentType = $ContentType }
    $Response.Headers["Access-Control-Allow-Origin"] = "*"
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Write-Json($Response, [int]$Status, $Obj) {
    $json = ($Obj | ConvertTo-Json -Compress -Depth 6)
    Write-Bytes $Response $Status "application/json" ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Relay-Request($Req, $Res) {
    $target = $Req.Headers["X-FF-Target"]
    if (-not $target -or ($target -notmatch '^https?://')) {
        Write-Json $Res 400 @{ error = @{ message = "Missing or invalid X-FF-Target header" } }
        return
    }
    $fwd = [System.Net.HttpWebRequest]::Create($target)
    $fwd.Method = $Req.HttpMethod
    $fwd.Timeout = 120000
    foreach ($h in $ForwardHeaders) {
        $v = $Req.Headers[$h]
        if ($v) { $fwd.Headers[$h] = $v }
    }
    $ct = $Req.Headers["Content-Type"]
    if ($ct) { $fwd.ContentType = $ct }
    if ($Req.HttpMethod -eq "POST") {
        $ms = New-Object System.IO.MemoryStream
        $Req.InputStream.CopyTo($ms)
        $body = $ms.ToArray()
        $fwd.ContentLength = $body.Length
        $rs = $fwd.GetRequestStream(); $rs.Write($body, 0, $body.Length); $rs.Close()
    }
    $resp = $null
    try {
        $resp = $fwd.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response   # non-2xx: pass the body through verbatim
        if (-not $resp) {
            Write-Json $Res 502 @{ error = @{ message = "Proxy could not reach upstream: $($_.Exception.Message)" } }
            return
        }
    }
    $stream = $resp.GetResponseStream()
    $out = New-Object System.IO.MemoryStream
    $stream.CopyTo($out)
    $bytes = $out.ToArray()
    $code = [int]$resp.StatusCode
    $rtype = $resp.ContentType; if (-not $rtype) { $rtype = "application/json" }
    $resp.Close()
    Write-Bytes $Res $code $rtype $bytes
}

function Serve-Static($Req, $Res) {
    $rel = [Uri]::UnescapeDataString($Req.Url.AbsolutePath.TrimStart('/'))
    if ([string]::IsNullOrWhiteSpace($rel)) { $rel = "index.html" }
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
    if (-not $full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Bytes $Res 403 "text/plain" ([System.Text.Encoding]::UTF8.GetBytes("Forbidden")); return
    }
    if (Test-Path $full -PathType Container) { $full = Join-Path $full "index.html" }
    if (Test-Path $full -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($full).ToLower()
        $type = if ($Mime.ContainsKey($ext)) { $Mime[$ext] } else { "application/octet-stream" }
        Write-Bytes $Res 200 $type ([System.IO.File]::ReadAllBytes($full))
    } else {
        Write-Bytes $Res 404 "text/plain" ([System.Text.Encoding]::UTF8.GetBytes("Not found"))
    }
}

while ($Listener.IsListening) {
    $ctx = $Listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        if ($req.HttpMethod -eq "OPTIONS") {
            $res.Headers["Access-Control-Allow-Origin"] = "*"
            $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            $res.Headers["Access-Control-Allow-Headers"] = "*"
            $res.StatusCode = 204
        }
        elseif ($req.Url.AbsolutePath -eq $ProxyPath) {
            Relay-Request $req $res
        }
        else {
            Serve-Static $req $res
        }
    } catch {
        try { Write-Json $res 500 @{ error = @{ message = "Proxy error: $($_.Exception.Message)" } } } catch {}
    } finally {
        try { $res.OutputStream.Close() } catch {}
    }
}
