<#
.SYNOPSIS
    JWT decoding helpers. No dependencies; unit-testable in isolation:
        Import-Module .\src\modules\Jwt.psm1 -Force
        ConvertFrom-Jwt $someToken
#>

Set-StrictMode -Version Latest

function ConvertFrom-Base64Url {
    <#
    .SYNOPSIS
        Decode a base64url string (JWT segment) into a UTF8 string.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    # base64url -> base64: swap chars and restore padding
    $b64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) {
        2 { $b64 += '==' }
        3 { $b64 += '=' }
        1 { throw "Invalid base64url string length." }
    }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
}

function ConvertFrom-Jwt {
    <#
    .SYNOPSIS
        Parse a JWT into its header and payload (claims) objects.
    .OUTPUTS
        PSCustomObject with Header, Payload, and Raw properties. Payload is the
        decoded claim set. Returns $null-ish object if the token isn't a JWT.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Token
    )

    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) {
        throw "Token is not a JWT (expected at least header.payload)."
    }

    $header  = ConvertFrom-Base64Url $parts[0] | ConvertFrom-Json
    $payload = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json

    [PSCustomObject]@{
        Header  = $header
        Payload = $payload
        Raw     = $Token
    }
}

function ConvertFrom-UnixTime {
    <#
    .SYNOPSIS
        Convert a Unix epoch-seconds value to local DateTime. Returns $null for
        missing/empty input.
    #>
    param($Seconds)

    if ($null -eq $Seconds -or "$Seconds" -eq '') { return $null }
    [System.DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds).LocalDateTime
}

Export-ModuleMember -Function ConvertFrom-Base64Url, ConvertFrom-Jwt, ConvertFrom-UnixTime
