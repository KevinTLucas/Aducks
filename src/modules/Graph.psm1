<#
.SYNOPSIS
    Microsoft Graph REST helpers + query URI builder. Stateless - every call
    takes the access token explicitly. 401 is surfaced separately so callers can
    clear auth state.
#>

Set-StrictMode -Version Latest

function Invoke-GraphRequest {
    <#
    .OUTPUTS @{ Ok; StatusCode; Data; Error; Unauthorized } - never throws for HTTP errors.
    #>
    param(
        [Parameter(Mandatory)] [string] $AccessToken,
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'GET',
        [hashtable] $Headers
    )
    $h = @{ Authorization = "Bearer $AccessToken" }
    if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
    try {
        $resp = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $h -ErrorAction Stop
        [PSCustomObject]@{ Ok = $true; StatusCode = 200; Data = $resp; Error = $null; Unauthorized = $false }
    }
    catch {
        # StrictMode-safe: probe optional properties via PSObject so a missing
        # Response/ErrorDetails never throws from inside the catch itself.
        $status = $null
        $respProp = $_.Exception.PSObject.Properties['Response']
        if ($respProp -and $respProp.Value) { try { $status = [int]$respProp.Value.StatusCode } catch { } }
        $msg = $null
        $edProp = $_.PSObject.Properties['ErrorDetails']
        if ($edProp -and $edProp.Value) { $msg = $edProp.Value.Message }
        if (-not $msg) { $msg = $_.Exception.Message }
        [PSCustomObject]@{ Ok = $false; StatusCode = $status; Data = $null; Error = $msg; Unauthorized = ($status -eq 401) }
    }
}

function Get-GraphMe {
    param([Parameter(Mandatory)][string] $AccessToken, [string] $MeUrl = 'https://graph.microsoft.com/v1.0/me')
    Invoke-GraphRequest -AccessToken $AccessToken -Uri $MeUrl
}

function Get-GraphPhoto {
    <#
    .SYNOPSIS
        Fetch the signed-in user's profile photo as raw bytes (JPEG), or $null if
        there's no photo / it can't be read. Never throws.
    .OUTPUTS [byte[]] or $null
    #>
    param(
        [Parameter(Mandatory)][string] $AccessToken,
        [string] $Base = 'https://graph.microsoft.com/v1.0'
    )
    try {
        $resp = Invoke-WebRequest -Uri "$Base/me/photo/`$value" -Headers @{ Authorization = "Bearer $AccessToken" } `
                                  -UseBasicParsing -ErrorAction Stop
        return $resp.Content
    } catch { return $null }
}

function New-GraphQueryUri {
    <#
    .SYNOPSIS
        Build a Graph URI from a config URL template. {value} is filled from the
        user's input (OData-escaped + URL-encoded); omit it for value-less
        endpoints like "me". A relative template is prefixed with $Base; a full
        https:// template is used as-is. Checked properties become $select.
    .OUTPUTS [string]
    #>
    param(
        [Parameter(Mandatory)] [string] $Url,
        [string] $Value,
        [string] $SelectCsv,
        [string] $Base = 'https://graph.microsoft.com/v1.0'
    )
    if (-not $Url) { throw "Lookup has no 'Url'." }

    # Double single quotes (OData), then URL-encode the value.
    $enc = [uri]::EscapeDataString(($Value -replace "'", "''"))
    $rel = $Url -replace '\{value\}', $enc
    $uri = if ($rel -match '^https?://') { $rel } else { "$Base/$rel" }

    if ($SelectCsv) {
        $sep = if ($uri.Contains('?')) { '&' } else { '?' }
        $uri += $sep + '$select=' + $SelectCsv
    }
    # Encode literal spaces/quotes left in the template (e.g. $filter / $search).
    $uri.Replace(' ', '%20').Replace('"', '%22')
}

# StrictMode-safe member read (missing property returns $null instead of throwing).
function Get-GraphMember {
    param($Obj, [string] $Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null }
}

# Resolve a dotted path like "value[0].id" against a parsed JSON object.
function Resolve-GraphPath {
    param($Obj, [string] $Path)
    $cur = $Obj
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        if ($seg -match '^(.*?)\[(\d+)\]$') {
            $name = $matches[1]; $idx = [int]$matches[2]
            if ($name) { $cur = Get-GraphMember $cur $name }
            if ($null -eq $cur) { return $null }
            $arr = @($cur)
            if ($idx -ge $arr.Count) { return $null }
            $cur = $arr[$idx]
        } else {
            $cur = Get-GraphMember $cur $seg
        }
    }
    $cur
}

function Invoke-GraphChain {
    <#
    .SYNOPSIS
        Run a chained lookup: each step's result feeds the next. Steps is an array
        of @{ Url; Extract }. Step 1's {value} is the user's input; each later
        step's {value} is the previous step's Extract path (e.g. "value[0].id").
        The last step's result is returned (with $select applied). Same output
        shape as Invoke-GraphRequest.
    .OUTPUTS @{ Ok; StatusCode; Data; Error; Unauthorized }
    #>
    param(
        [Parameter(Mandatory)] [string] $AccessToken,
        [Parameter(Mandatory)] $Steps,
        [string] $Value,
        [string] $SelectCsv,
        [string] $Base = 'https://graph.microsoft.com/v1.0',
        [hashtable] $Headers
    )
    $steps = @($Steps)
    $val = $Value
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        $isLast = ($i -eq $steps.Count - 1)
        $sel = if ($isLast) { $SelectCsv } else { '' }
        try {
            $uri = New-GraphQueryUri -Url (Get-GraphMember $step 'Url') -Value $val -SelectCsv $sel -Base $Base
        } catch {
            return [PSCustomObject]@{ Ok = $false; StatusCode = $null; Data = $null; Error = "Step $($i+1): $($_.Exception.Message)"; Unauthorized = $false }
        }
        $r = Invoke-GraphRequest -AccessToken $AccessToken -Uri $uri -Headers $Headers
        if (-not $r.Ok) { return $r }          # propagate HTTP error / 401
        if ($isLast) { return $r }

        $extract = Get-GraphMember $step 'Extract'
        if (-not $extract) {
            return [PSCustomObject]@{ Ok = $false; StatusCode = $null; Data = $null; Error = "Step $($i+1) is missing an 'Extract' path."; Unauthorized = $false }
        }
        $val = Resolve-GraphPath $r.Data $extract
        if ($null -eq $val -or "$val" -eq '') {
            return [PSCustomObject]@{ Ok = $false; StatusCode = $null; Data = $null; Error = "No match: step $($i+1) returned nothing at '$extract'. Check the value you entered."; Unauthorized = $false }
        }
        $val = "$val"
    }
}

Export-ModuleMember -Function Invoke-GraphRequest, Get-GraphMe, Get-GraphPhoto, New-GraphQueryUri, Invoke-GraphChain
