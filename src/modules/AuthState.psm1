<#
.SYNOPSIS
    In-memory authentication state + expiry logic. Holds the captured access
    token (never persisted to disk), its decoded JWT, the signed-in user, and
    derived timing. Pure state/logic - the UI reads from it, it does no UI work.

    Depends on Jwt.psm1 (ConvertFrom-Jwt, ConvertFrom-UnixTime) being imported.
#>

Set-StrictMode -Version Latest

function New-AuthState {
    <#
    .SYNOPSIS
        Create an empty (signed-out) auth state object.
    #>
    [PSCustomObject]@{
        IsAuthenticated = $false
        AccessToken     = $null
        Jwt             = $null      # PSCustomObject from ConvertFrom-Jwt
        User            = $null      # Graph /me response
        CapturedAt      = $null      # [datetime] when token was captured
        IssuedAt        = $null      # [datetime] from iat
        ExpiresAt       = $null      # [datetime] from exp
        Scopes          = @()        # string[] from scp
        TokenType       = 'Bearer'
        TenantName      = $null      # from /organization displayName
        Photo           = $null      # byte[] from /me/photo/$value
    }
}

function Set-AuthStateToken {
    <#
    .SYNOPSIS
        Populate state from a captured access token. Decodes the JWT and derives
        expiry + scopes. Throws if the token isn't a decodable JWT.
    #>
    param(
        [Parameter(Mandatory)] [PSCustomObject] $State,
        [Parameter(Mandatory)] [string] $AccessToken
    )

    $jwt = ConvertFrom-Jwt -Token $AccessToken

    $exp = $null; $iat = $null
    if ($jwt.Payload.PSObject.Properties.Name -contains 'exp') { $exp = ConvertFrom-UnixTime $jwt.Payload.exp }
    if ($jwt.Payload.PSObject.Properties.Name -contains 'iat') { $iat = ConvertFrom-UnixTime $jwt.Payload.iat }

    $scopes = @()
    if ($jwt.Payload.PSObject.Properties.Name -contains 'scp' -and $jwt.Payload.scp) {
        $scopes = @($jwt.Payload.scp -split '\s+' | Where-Object { $_ })
    }

    $State.IsAuthenticated = $true
    $State.AccessToken     = $AccessToken
    $State.Jwt             = $jwt
    $State.CapturedAt      = Get-Date
    $State.IssuedAt        = $iat
    $State.ExpiresAt       = $exp
    $State.Scopes          = $scopes
    $State
}

function Set-AuthStateUser {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $State,
        [Parameter(Mandatory)] $User
    )
    $State.User = $User
    $State
}

function Clear-AuthState {
    <#
    .SYNOPSIS
        Wipe all auth data in place (sign out / expiry / rejection).
    #>
    param([Parameter(Mandatory)] [PSCustomObject] $State)

    $State.IsAuthenticated = $false
    $State.AccessToken     = $null
    $State.Jwt             = $null
    $State.User            = $null
    $State.CapturedAt      = $null
    $State.IssuedAt        = $null
    $State.ExpiresAt       = $null
    $State.Scopes          = @()
    $State.TenantName      = $null
    $State.Photo           = $null
    $State
}

function Get-RemainingLifetime {
    <#
    .SYNOPSIS
        [TimeSpan] until token exp. Zero if expired/unknown.
    #>
    param([Parameter(Mandatory)] [PSCustomObject] $State)

    if (-not $State.ExpiresAt) { return [TimeSpan]::Zero }
    $remaining = $State.ExpiresAt - (Get-Date)
    if ($remaining -lt [TimeSpan]::Zero) { [TimeSpan]::Zero } else { $remaining }
}

function Test-AuthStateExpired {
    <#
    .SYNOPSIS
        True if the token is at/past exp (minus a safety skew).
    #>
    param(
        [Parameter(Mandatory)] [PSCustomObject] $State,
        [int] $SkewSec = 30
    )

    if (-not $State.IsAuthenticated) { return $true }
    if (-not $State.ExpiresAt) { return $false }   # no exp claim: don't force-expire
    (Get-Date) -ge $State.ExpiresAt.AddSeconds(-$SkewSec)
}

Export-ModuleMember -Function New-AuthState, Set-AuthStateToken, Set-AuthStateUser, `
    Clear-AuthState, Get-RemainingLifetime, Test-AuthStateExpired
