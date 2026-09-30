<#
.SYNOPSIS
    Token capture via Microsoft Edge + Chrome DevTools Protocol (CDP).

    Launches an isolated Edge instance at Graph Explorer with a remote-debugging
    port, then watches that page's network traffic and grabs the
    'Authorization: Bearer <token>' header from the first request to
    graph.microsoft.com after the user signs in.

    Debuggable standalone:
        Import-Module .\src\modules\Cdp.psm1 -Force
        . .\src\Config.ps1
        Invoke-GraphTokenCapture -Config (Get-AducksConfig) -Verbose

    Notes:
      * Only the Authorization header of graph.microsoft.com requests is read.
      * The Edge profile is a throwaway temp dir, deleted on cleanup.
      * Blocking by design; run it on a background runspace so the UI stays live.
#>

Set-StrictMode -Version Latest

function Get-FreeTcpPort {
    <# Reserve a free localhost TCP port and release it for Edge to bind. #>
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Find-Browser {
    <#
    .SYNOPSIS
        Resolve the Chromium browser exe to launch. $Preference is 'edge',
        'chrome', or a full path to a Chromium browser. CDP capture requires a
        Chromium browser (Edge/Chrome) - Firefox/Safari won't work.
    #>
    param([string] $Preference = 'edge')

    # Explicit full path wins.
    if ($Preference -and ($Preference -match '\.exe$')) {
        if (Test-Path $Preference) { return $Preference }
        throw "Browser path not found: $Preference (check 'Browser' in config\settings.json)."
    }

    if (($Preference).ToLower() -in @('chrome', 'googlechrome', 'google chrome')) {
        $exe = 'chrome.exe'; $sub = 'Google\Chrome\Application\chrome.exe'; $name = 'Google Chrome'
    } else {
        $exe = 'msedge.exe'; $sub = 'Microsoft\Edge\Application\msedge.exe'; $name = 'Microsoft Edge'
    }

    foreach ($root in 'HKLM:', 'HKCU:') {
        $p = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
        try {
            $val = (Get-ItemProperty -Path $p -ErrorAction Stop).'(default)'
            if ($val -and (Test-Path $val)) { return $val }
        } catch { }
    }
    foreach ($base in ${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) {
        if ($base) { $c = Join-Path $base $sub; if (Test-Path $c) { return $c } }
    }
    throw "$name was not found. Set 'Browser' in config\settings.json to 'edge', 'chrome', or a full path to a Chromium browser."
}

function Start-EdgeForCapture {
    <#
    .SYNOPSIS
        Launch an isolated Chromium (Edge/Chrome) instance at $Url with remote
        debugging on $Port.
    .OUTPUTS
        @{ Process; ProfileDir; Port }
    #>
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $Url,
        [string] $Browser = 'edge'
    )

    $edge = Find-Browser -Preference $Browser
    $profileDir = Join-Path $env:TEMP ("Aducks-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

    $args = @(
        "--remote-debugging-port=$Port"
        "--user-data-dir=`"$profileDir`""
        '--no-first-run'
        '--no-default-browser-check'
        '--new-window'
        $Url
    )
    Write-Verbose "Launching Edge: $edge $($args -join ' ')"
    $proc = Start-Process -FilePath $edge -ArgumentList $args -PassThru

    [PSCustomObject]@{ Process = $proc; ProfileDir = $profileDir; Port = $Port }
}

function Get-CdpPageWebSocketUrl {
    <#
    .SYNOPSIS
        Poll the CDP HTTP endpoint until the Graph Explorer page target exposes a
        WebSocket debugger URL. Throws on timeout (e.g. remote debugging blocked
        by policy).
    #>
    param(
        [Parameter(Mandatory)] [int] $Port,
        [int] $TimeoutSec = 30,
        [string] $PreferUrlContains   # keep waiting for the tab whose URL contains this (e.g. the Graph Explorer host)
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $fallback = $null
    while ((Get-Date) -lt $deadline) {
        foreach ($listUrl in @("http://localhost:$Port/json/list", "http://localhost:$Port/json")) {
            try {
                $targets = Invoke-RestMethod -Uri $listUrl -TimeoutSec 3 -ErrorAction Stop
            } catch { continue }

            $pages = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
            if ($pages.Count -gt 0) {
                if ($PreferUrlContains) {
                    $needle = $PreferUrlContains.ToLower()
                    $match = $pages | Where-Object { $_.url -and $_.url.ToLower().Contains($needle) } | Select-Object -First 1
                    if ($match) { Write-Verbose "CDP page target: $($match.url)"; return $match.webSocketDebuggerUrl }
                    $fallback = $pages[0]   # remember, but keep waiting for the preferred tab (avoids grabbing a new-tab page)
                } else {
                    return $pages[0].webSocketDebuggerUrl
                }
            }
        }
        Start-Sleep -Milliseconds 400
    }
    if ($fallback) { Write-Verbose "Preferred tab not found; using $($fallback.url)"; return $fallback.webSocketDebuggerUrl }
    throw "Could not reach the browser's remote-debugging endpoint on port $Port within $TimeoutSec s. Remote debugging may be disabled by device policy (RemoteDebuggingAllowed=0)."
}

function Wait-GraphAuthToken {
    <#
    .SYNOPSIS
        Connect to the page's CDP WebSocket, enable the Network domain, and
        return the first Bearer token seen on a request to $Prefix. Throws on
        timeout.
    #>
    param(
        [Parameter(Mandatory)] [string] $WebSocketUrl,
        [Parameter(Mandatory)] [string] $Prefix,
        [int] $TimeoutSec = 300,
        [string] $ClickSelector
    )

    $ws     = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts    = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    $buffer = [byte[]]::new(16384)

    function Send-Cdp {
        param([string] $Text)
        $b = [System.Text.Encoding]::UTF8.GetBytes($Text)
        [void]$ws.SendAsync([System.ArraySegment[byte]]::new($b), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
    }

    function Receive-Cdp {
        # Read one full CDP message; returns the parsed object, or $null on close.
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            $r = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), $cts.Token).GetAwaiter().GetResult()
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $r.Count))
            if ($r.EndOfMessage) { break }
        }
        try { $sb.ToString() | ConvertFrom-Json } catch { $null }
    }

    function Get-TokenFromEvent {
        # Return the Bearer token if $o is a graph.microsoft.com request, else $null.
        param($o)
        if (-not $o -or ($o.PSObject.Properties.Name -notcontains 'method') -or $o.method -ne 'Network.requestWillBeSent') { return $null }
        $request = $o.params.request
        if (-not $request.url.StartsWith($Prefix)) { return $null }
        if ($request.PSObject.Properties.Name -notcontains 'headers' -or -not $request.headers) { return $null }
        foreach ($h in $request.headers.PSObject.Properties) {
            if ($h.Name -ieq 'authorization' -and "$($h.Value)" -imatch '^Bearer\s+(.+)$') {
                Write-Verbose "Captured token from $($request.url)"
                return $matches[1].Trim()
            }
        }
        $null
    }

    try {
        [void]$ws.ConnectAsync([Uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
        Send-Cdp '{"id":1,"method":"Network.enable"}'

        # Auto-click the Sign-in button. Retry a fresh Runtime.evaluate (with
        # userGesture, so MSAL's login popup isn't blocked) until the button
        # exists and is clicked, or ~30s pass. A token seen meanwhile short-circuits.
        if ($ClickSelector) {
            $expr = "(function(){try{var b=document.querySelector('$ClickSelector');if(b){b.click();return 'clicked';}}catch(e){}return 'notfound';})()"
            Write-Verbose "Auto-click selector: $ClickSelector"
            for ($try = 0; $try -lt 40; $try++) {
                $id = 1000 + $try
                Send-Cdp ((@{ id = $id; method = 'Runtime.evaluate'; params = @{ expression = $expr; userGesture = $true; returnByValue = $true } } | ConvertTo-Json -Compress))
                $clicked = $false
                while ($true) {
                    $o = Receive-Cdp
                    if (-not $o) { throw "WebSocket closed during sign-in." }
                    $tok = Get-TokenFromEvent $o; if ($tok) { return $tok }
                    if (($o.PSObject.Properties.Name -contains 'id') -and $o.id -eq $id) {
                        $val = $null; try { $val = $o.result.result.value } catch { }
                        if ($val -eq 'clicked') { $clicked = $true }
                        break
                    }
                }
                if ($clicked) { Write-Verbose 'Clicked Sign in'; break }
                Start-Sleep -Milliseconds 750
            }
        }

        # Watch for the token on the next graph.microsoft.com request.
        while ($true) {
            $o = Receive-Cdp
            if (-not $o) { break }
            $tok = Get-TokenFromEvent $o; if ($tok) { return $tok }
        }
        throw "WebSocket closed before a Graph token was seen."
    }
    catch [System.OperationCanceledException] {
        throw "Timed out after $TimeoutSec s waiting for a Graph request. Did sign-in complete?"
    }
    finally {
        try { if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        } } catch { }
        $ws.Dispose(); $cts.Dispose()
    }
}

function Stop-EdgeCapture {
    <# Kill the launched Edge and delete its throwaway profile. #>
    param([Parameter(Mandatory)] [PSCustomObject] $Session)

    try { if ($Session.Process -and -not $Session.Process.HasExited) { $Session.Process.Kill() } } catch { }
    try { if ($Session.ProfileDir -and (Test-Path $Session.ProfileDir)) {
        Remove-Item -Path $Session.ProfileDir -Recurse -Force -ErrorAction SilentlyContinue
    } } catch { }
}

function Invoke-GraphTokenCapture {
    <#
    .SYNOPSIS
        Full capture orchestration: launch Edge, wait for login + Graph call,
        return the access token, and clean up. Blocking.
    .OUTPUTS
        [string] access token. Throws on failure/timeout (Edge is cleaned up).
    #>
    param([Parameter(Mandatory)] $Config)

    $browser = 'edge'
    $bp = $Config.PSObject.Properties['Browser']
    if ($bp -and $bp.Value) { $browser = $bp.Value }

    # Selector for the button auto-clicked to open the login prompt. Configurable
    # (Graph Explorer's markup can change); empty string disables auto-click.
    $selector = 'button[aria-label="Sign in"]'
    $sp = $Config.PSObject.Properties['SignInSelector']
    if ($sp) { $selector = $sp.Value }

    $prefer = ''
    try { $prefer = ([Uri]$Config.GraphExplorerUrl).Host } catch { }

    $session = $null
    try {
        $port    = Get-FreeTcpPort
        $session = Start-EdgeForCapture -Port $port -Url $Config.GraphExplorerUrl -Browser $browser
        $wsUrl   = Get-CdpPageWebSocketUrl -Port $port -TimeoutSec $Config.CdpEndpointTimeoutSec -PreferUrlContains $prefer
        $token   = Wait-GraphAuthToken -WebSocketUrl $wsUrl -Prefix $Config.GraphRequestPrefix `
                                       -TimeoutSec $Config.CaptureTimeoutSec -ClickSelector $selector
        return $token
    }
    finally {
        if ($session) { Stop-EdgeCapture -Session $session }
    }
}

Export-ModuleMember -Function Get-FreeTcpPort, Find-Browser, Start-EdgeForCapture, `
    Get-CdpPageWebSocketUrl, Wait-GraphAuthToken, Stop-EdgeCapture, Invoke-GraphTokenCapture
