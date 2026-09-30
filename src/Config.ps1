<#
.SYNOPSIS
    Loads Aducks configuration.

    Technical constants (Graph endpoints, CDP/timer intervals) live here as code
    defaults - an end user would never change them, so they're kept out of the
    JSON. settings.json holds only the handful of options a user might actually
    want to change (browser, sign-in selector, login wait, UI wording) and
    overrides the matching defaults. queries.json holds the query catalog.
#>

$script:AducksConfigDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'config'

# Defaults for everything the code reads off $Config. settings.json overrides
# only the keys it contains; the rest fall back to these.
$script:AducksDefaults = [ordered]@{
    GraphExplorerUrl      = 'https://developer.microsoft.com/en-us/graph/graph-explorer'
    GraphV1               = 'https://graph.microsoft.com/v1.0'
    GraphMeUrl            = 'https://graph.microsoft.com/v1.0/me'
    GraphRequestPrefix    = 'https://graph.microsoft.com/'
    CdpEndpointTimeoutSec = 30
    CaptureTimeoutSec     = 300
    CountdownIntervalMs   = 1000
    RevalidateIntervalSec = 120
    ExpirySkewSec         = 30
    SignInSelector        = 'button[aria-label="Sign in"]'
    Browser               = 'edge'
}

function Read-AducksJson {
    param([Parameter(Mandatory)][string] $Name)
    $path = Join-Path $script:AducksConfigDir $Name
    if (-not (Test-Path $path)) { throw "Config file not found: $path" }
    try { (Get-Content -Raw -Path $path) | ConvertFrom-Json }
    catch { throw "Invalid JSON in $path : $($_.Exception.Message)" }
}

$script:AducksSettings   = Read-AducksJson 'settings.json'
$script:AducksQueries    = Read-AducksJson 'queries.json'
$script:AducksCategories = $script:AducksQueries.categories

function Get-AducksConfig {
    # defaults, then overlay user settings (ignoring _note keys)
    $merged = @{}
    foreach ($k in $script:AducksDefaults.Keys) { $merged[$k] = $script:AducksDefaults[$k] }
    foreach ($p in $script:AducksSettings.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $merged[$p.Name] = $p.Value
    }
    [PSCustomObject]$merged
}

function Get-AducksCategories { $script:AducksCategories }

function Get-AducksQueriesPath  { Join-Path $script:AducksConfigDir 'queries.json' }
function Get-AducksSettingsPath { Join-Path $script:AducksConfigDir 'settings.json' }

# The parsed settings.json (keeps its _note keys) for the in-app settings editor.
function Get-AducksSettingsRaw { $script:AducksSettings }

# Re-read settings.json after the editor saves. Callers then rebuild their
# merged config via Get-AducksConfig.
function Reload-AducksSettings {
    $script:AducksSettings = Read-AducksJson 'settings.json'
    $script:AducksSettings
}

# Pretty-print a JSON string via Newtonsoft (2-space, no \uXXXX escaping of
# < > & '). Falls back to the input if it can't be parsed.
function ConvertTo-PrettyJson {
    param([string] $Json)
    if (-not $Json) { return $Json }
    try { [Newtonsoft.Json.Linq.JToken]::Parse($Json).ToString([Newtonsoft.Json.Formatting]::Indented) }
    catch { $Json }
}

# Write an object to a JSON file: pretty-printed (Newtonsoft), UTF-8 no BOM,
# so the file stays clean and hand-editable.
function Save-AducksJsonFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Root)
    $json = ConvertTo-PrettyJson ($Root | ConvertTo-Json -Depth 12)
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# The catalog's _readme text, preserved when the in-app editor rewrites the file.
function Get-AducksReadme {
    $p = $script:AducksQueries.PSObject.Properties['_readme']
    if ($p) { $p.Value } else { '' }
}

# Re-read queries.json from disk (after the editor saves) and return the fresh
# categories, updating the cached copy Get-AducksCategories returns.
function Reload-AducksCategories {
    $script:AducksQueries    = Read-AducksJson 'queries.json'
    $script:AducksCategories = $script:AducksQueries.categories
    $script:AducksCategories
}

# Write a catalog object (@{ _readme; categories }) back to queries.json.
function Save-AducksQueriesFile {
    param([Parameter(Mandatory)] $Root)
    Save-AducksJsonFile -Path (Get-AducksQueriesPath) -Root $Root
}

# Write a settings object back to settings.json.
function Save-AducksSettingsFile {
    param([Parameter(Mandatory)] $Root)
    Save-AducksJsonFile -Path (Get-AducksSettingsPath) -Root $Root
}
