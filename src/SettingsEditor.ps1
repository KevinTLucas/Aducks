<#
.SYNOPSIS
    In-app editor for settings.json. Opened from the settings cog in the profile
    popup. Simple form (no master/detail): browser, sign-in selector, login wait,
    and the four query-builder step labels. Save writes settings.json (preserving
    its _note keys and order) and refreshes the app via -OnSaved.

    Dot-sourced by Main.ps1; shares Import-Xaml, Get-Prop and the Config helpers.
#>

Set-StrictMode -Version Latest

$script:se        = @{}
$script:seWin     = $null
$script:seOnSaved = $null

function Se-Res { param($Key) $script:seWin.FindResource($Key) }

function Se-SetStatus {
    param([string] $Text, [string] $BrushKey = 'BadBrush')
    $script:se.SettingsStatus.Text = $Text
    $script:se.SettingsStatus.Foreground = Se-Res $BrushKey
}

function Se-Save {
    $raw = Get-AducksSettingsRaw

    # validate login wait
    $timeout = 0
    if (-not [int]::TryParse($script:se.EditTimeout.Text.Trim(), [ref]$timeout) -or $timeout -le 0) {
        Se-SetStatus 'Login wait must be a whole number of seconds greater than 0.' 'BadBrush'; return
    }
    if (-not $script:se.EditBrowser.Text.Trim()) {
        Se-SetStatus "Browser can't be empty (use 'edge', 'chrome', or a full path)." 'BadBrush'; return
    }

    # rebuild root from the existing file (keeps _note keys + order), overriding
    # the managed values. Drop any legacy Labels (now hard-coded, not editable).
    $root = [ordered]@{}
    foreach ($p in $raw.PSObject.Properties) {
        if ($p.Name -in 'Labels','_labels_note') { continue }
        $root[$p.Name] = $p.Value
    }
    $root['Browser']           = $script:se.EditBrowser.Text.Trim()
    $root['SignInSelector']    = $script:se.EditSelector.Text
    $root['CaptureTimeoutSec'] = $timeout

    try { Save-AducksSettingsFile -Root $root }
    catch { Se-SetStatus ("Could not save: {0}" -f $_.Exception.Message) 'BadBrush'; return }

    if ($script:seOnSaved) { try { & $script:seOnSaved } catch { } }
    $script:seWin.Close()
}

function Show-SettingsEditor {
    param(
        [Parameter(Mandatory)] $Owner,
        [scriptblock] $OnSaved
    )
    $script:seOnSaved = $OnSaved

    $script:seWin = Import-Xaml (Join-Path $UiRoot 'SettingsEditor.xaml')
    $script:seWin.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $UiRoot 'Theme.xaml')))
    $script:seWin.Owner = $Owner
    Initialize-WindowChrome $script:seWin

    $script:se = @{}
    foreach ($n in @(
        'EditBrowser','EditSelector','EditTimeout',
        'SettingsStatus','CancelButton','SaveButton'
    )) { $script:se[$n] = $script:seWin.FindName($n) }

    # load current values (fresh from disk)
    $raw = Reload-AducksSettings
    $script:se.EditBrowser.Text  = [string](Get-Prop $raw 'Browser')
    $script:se.EditSelector.Text = [string](Get-Prop $raw 'SignInSelector')
    $script:se.EditTimeout.Text  = [string](Get-Prop $raw 'CaptureTimeoutSec')

    $script:se.SaveButton.Add_Click({ Se-Save })
    $script:se.CancelButton.Add_Click({ $script:seWin.Close() })

    [void]$script:seWin.ShowDialog()
}
