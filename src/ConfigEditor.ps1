<#
.SYNOPSIS
    In-app editor for the query catalog (config/queries.json). Opened from the
    settings cog on the Build-a-query card. Master/detail: pick a query on the
    left, edit its category, name, return properties and lookups on the right,
    then Save (writes queries.json and refreshes the builder via -OnSaved).

    Dot-sourced by Main.ps1, so it shares Import-Xaml, Get-Prop and the Config
    helpers (Get-AducksReadme, Save-AducksQueriesFile, ...).

    The catalog is edited as a FLAT list of query objects (each carries its own
    Category); categories are regrouped on save, so moving a query between
    categories is just editing a text field.
#>

Set-StrictMode -Version Latest

$script:ce         = @{}      # editor controls
$script:ceWin      = $null
$script:ceQueries  = $null    # ArrayList of [ordered]@{ Category; Label; Note; Props; Lookups }
$script:ceCurrent  = $null    # currently edited query (ref into ceQueries)
$script:ceOnSaved  = $null

function Ce-Res { param($Key) $script:ceWin.FindResource($Key) }

function Ce-SetStatus {
    param([string] $Text, [string] $BrushKey = 'BadBrush')
    $script:ce.EditorStatus.Text = $Text
    $script:ce.EditorStatus.Foreground = Ce-Res $BrushKey
}

function Ce-DistinctCategories {
    $seen = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($q in $script:ceQueries) { if ($q.Category -and -not $seen.Contains($q.Category)) { $seen.Add($q.Category, $true) } }
    @($seen.Keys)
}

# ---- lookup rows (built in code; refs stashed on each row's Tag) ----------
function Ce-NewLabel {
    param([string] $Text)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = 11; $t.FontWeight = 'SemiBold'
    $t.Foreground = Ce-Res 'MutedBrush'; $t.Margin = '0,0,0,3'
    $t
}
function Ce-NewInput {
    param([string] $Value, [string] $Margin = '0,0,0,8')
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Style = Ce-Res 'InputBox'; $tb.Text = [string]$Value; $tb.Margin = $Margin
    $tb
}

# Renumber steps and hide the last step's Extract (it isn't used - that result
# is what gets shown). Called after any add/remove.
function Ce-RefreshSteps {
    param($StepsHost)
    $rows = @($StepsHost.Children); $n = $rows.Count
    for ($i = 0; $i -lt $n; $i++) {
        $t = $rows[$i].Tag
        $t.Num.Text = "STEP $($i + 1)   (use {value})"
        $t.ExtractPanel.Visibility = if ($i -eq $n - 1) { 'Collapsed' } else { 'Visible' }
    }
}

# One step of a chained lookup: URL + Extract, with a remove button.
function Ce-AddStepRow {
    param($StepsHost, [string] $Url, [string] $Extract)
    $row = New-Object System.Windows.Controls.Border
    $row.Background = Ce-Res 'PanelBrush'; $row.BorderBrush = Ce-Res 'BorderBrush2'
    $row.BorderThickness = 1; $row.CornerRadius = 6; $row.Padding = 8; $row.Margin = '0,0,0,6'
    $st = New-Object System.Windows.Controls.StackPanel

    $head = New-Object System.Windows.Controls.DockPanel; $head.Margin = '0,0,0,3'
    $x = New-Object System.Windows.Controls.Button
    $x.Content = 'Remove'; $x.Style = Ce-Res 'GhostButton'; $x.Padding = '8,2'; $x.FontSize = 10
    [System.Windows.Controls.DockPanel]::SetDock($x, 'Right')
    $x.Tag = $row
    $x.Add_Click({ param($s, $e) $p = $s.Tag.Parent; if ($p) { $p.Children.Remove($s.Tag); Ce-RefreshSteps $p } })
    [void]$head.Children.Add($x)
    $numLbl = Ce-NewLabel 'STEP   (use {value})'
    [void]$head.Children.Add($numLbl)
    [void]$st.Children.Add($head)

    $tbU = Ce-NewInput $Url '0,0,0,6'
    [void]$st.Children.Add($tbU)

    # Extract label + box, grouped so it can be hidden on the last step.
    $extractPanel = New-Object System.Windows.Controls.StackPanel
    [void]$extractPanel.Children.Add((Ce-NewLabel 'EXTRACT   (path to the value passed to the next step, e.g. value[0].id)'))
    $tbE = Ce-NewInput $Extract '0'
    [void]$extractPanel.Children.Add($tbE)
    [void]$st.Children.Add($extractPanel)

    $row.Child = $st
    $row.Tag = @{ Url = $tbU; Extract = $tbE; Num = $numLbl; ExtractPanel = $extractPanel }
    [void]$StepsHost.Children.Add($row)
    Ce-RefreshSteps $StepsHost
}

function Ce-AddLookupRow {
    param([string] $Label, [string] $Url, [string] $Hint, [string] $VLabel, $Chain)

    $border = New-Object System.Windows.Controls.Border
    $border.Background = Ce-Res 'PanelBrush2'
    $border.BorderBrush = Ce-Res 'BorderBrush2'; $border.BorderThickness = 1
    $border.CornerRadius = 8; $border.Padding = 10; $border.Margin = '0,0,0,8'

    $stack = New-Object System.Windows.Controls.StackPanel

    # header row: label caption + remove button
    $head = New-Object System.Windows.Controls.DockPanel
    $rm = New-Object System.Windows.Controls.Button
    $rm.Content = 'Remove'; $rm.Style = Ce-Res 'GhostButton'; $rm.Padding = '10,4'; $rm.FontSize = 11
    [System.Windows.Controls.DockPanel]::SetDock($rm, 'Right')
    $rm.Add_Click({ param($s, $e) $script:ce.LookupsPanel.Children.Remove($s.Tag) })
    $rm.Tag = $border
    [void]$head.Children.Add($rm)
    [void]$head.Children.Add((Ce-NewLabel 'LOOKUP NAME'))
    $head.Margin = '0,0,0,3'
    [void]$stack.Children.Add($head)

    $tbLabel = Ce-NewInput $Label
    [void]$stack.Children.Add($tbLabel)

    # chained toggle
    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.Content = 'This lookup runs multiple chained steps (result of one feeds the next)'
    $chk.Style = Ce-Res 'Check'; $chk.Margin = '0,4,0,8'
    $chk.IsChecked = [bool]$Chain
    [void]$stack.Children.Add($chk)

    # single-URL panel
    $singlePanel = New-Object System.Windows.Controls.StackPanel
    [void]$singlePanel.Children.Add((Ce-NewLabel 'GRAPH URL   (use {value} for user input)'))
    $tbUrl = Ce-NewInput $Url '0'
    [void]$singlePanel.Children.Add($tbUrl)
    [void]$stack.Children.Add($singlePanel)

    # steps panel
    $stepsPanel = New-Object System.Windows.Controls.StackPanel
    [void]$stepsPanel.Children.Add((Ce-NewLabel 'STEPS   (run in order; each URL uses {value} from the previous step)'))
    $stepsHost = New-Object System.Windows.Controls.StackPanel
    [void]$stepsPanel.Children.Add($stepsHost)
    $addStep = New-Object System.Windows.Controls.Button
    $addStep.Content = '+ Add step'; $addStep.Style = Ce-Res 'GhostButton'; $addStep.Padding = '10,4'
    $addStep.FontSize = 11; $addStep.HorizontalAlignment = 'Left'
    $addStep.Tag = $stepsHost
    $addStep.Add_Click({ param($s, $e) Ce-AddStepRow $s.Tag '' '' })
    [void]$stepsPanel.Children.Add($addStep)
    [void]$stack.Children.Add($stepsPanel)

    if ($Chain) { foreach ($s in @($Chain)) { Ce-AddStepRow $stepsHost ([string]$s['Url']) ([string]$s['Extract']) } }

    # initial visibility per toggle
    if ($Chain) { $singlePanel.Visibility = 'Collapsed'; $stepsPanel.Visibility = 'Visible' }
    else { $stepsPanel.Visibility = 'Collapsed' }

    $chk.Tag = @{ Single = $singlePanel; Steps = $stepsPanel; Host = $stepsHost }
    $chk.Add_Click({
        param($s, $e)
        $r = $s.Tag
        if ($s.IsChecked) {
            $r.Single.Visibility = 'Collapsed'; $r.Steps.Visibility = 'Visible'
            if ($r.Host.Children.Count -eq 0) { Ce-AddStepRow $r.Host '' ''; Ce-AddStepRow $r.Host '' '' }
        } else {
            $r.Single.Visibility = 'Visible'; $r.Steps.Visibility = 'Collapsed'
        }
    })

    # two-up optional fields
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,10,0,0'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '10'
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = '*'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2); $grid.ColumnDefinitions.Add($c3)

    $left  = New-Object System.Windows.Controls.StackPanel
    [void]$left.Children.Add((Ce-NewLabel 'EXAMPLE VALUE   (optional)'))
    $tbHint = Ce-NewInput $Hint '0'
    [void]$left.Children.Add($tbHint)
    [System.Windows.Controls.Grid]::SetColumn($left, 0)

    $right = New-Object System.Windows.Controls.StackPanel
    [void]$right.Children.Add((Ce-NewLabel 'VALUE LABEL   (optional)'))
    $tbVLabel = Ce-NewInput $VLabel '0'
    [void]$right.Children.Add($tbVLabel)
    [System.Windows.Controls.Grid]::SetColumn($right, 2)

    [void]$grid.Children.Add($left); [void]$grid.Children.Add($right)
    [void]$stack.Children.Add($grid)

    $border.Child = $stack
    $border.Tag = @{ Label = $tbLabel; Url = $tbUrl; Hint = $tbHint; VLabel = $tbVLabel; Chk = $chk; StepsHost = $stepsHost }
    [void]$script:ce.LookupsPanel.Children.Add($border)
}

# ---- master list ----------------------------------------------------------
function Ce-BuildList {
    $script:ce.QueryListPanel.Children.Clear()
    foreach ($cat in Ce-DistinctCategories) {
        $hdr = New-Object System.Windows.Controls.TextBlock
        $hdr.Text = $cat.ToUpper(); $hdr.FontSize = 11; $hdr.FontWeight = 'SemiBold'
        $hdr.Foreground = Ce-Res 'MutedBrush'; $hdr.Margin = '2,10,0,4'
        [void]$script:ce.QueryListPanel.Children.Add($hdr)

        foreach ($q in @($script:ceQueries | Where-Object { $_.Category -eq $cat })) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = $q.Label; $btn.Style = Ce-Res 'ConfigListItem'
            $btn.HorizontalAlignment = 'Stretch'; $btn.Tag = $q
            if ($q -eq $script:ceCurrent) { $btn.Background = Ce-Res 'AccentBrush2' }
            $btn.Add_Click({ param($s, $e) Ce-SelectQuery $s.Tag })
            [void]$script:ce.QueryListPanel.Children.Add($btn)
        }
    }
}

# ---- form load / commit ---------------------------------------------------
function Ce-LoadForm {
    param($Q)
    if (-not $Q) {
        $script:ce.FieldsPanel.Visibility = 'Collapsed'
        $script:ce.EmptyHint.Visibility   = 'Visible'
        $script:ce.DeleteQueryButton.IsEnabled = $false
        return
    }
    $script:ce.EmptyHint.Visibility   = 'Collapsed'
    $script:ce.FieldsPanel.Visibility = 'Visible'
    $script:ce.DeleteQueryButton.IsEnabled = $true

    $script:ce.EditCategory.Items.Clear()
    foreach ($c in Ce-DistinctCategories) { [void]$script:ce.EditCategory.Items.Add($c) }
    $script:ce.EditCategory.Text = [string]$Q.Category
    $script:ce.EditName.Text     = [string]$Q.Label
    $script:ce.EditProps.Text    = (@($Q.Props) -join "`r`n")

    $script:ce.LookupsPanel.Children.Clear()
    foreach ($l in $Q.Lookups) {
        Ce-AddLookupRow -Label ([string]$l['Label']) -Url ([string]$l['Url']) `
                        -Hint ([string]$l['ValueHint']) -VLabel ([string]$l['ValueLabel']) -Chain $l['Chain']
    }
}

# Read the form back into $script:ceCurrent (called before switching/saving).
function Ce-CommitForm {
    if (-not $script:ceCurrent) { return }
    $script:ceCurrent.Category = $script:ce.EditCategory.Text.Trim()
    $script:ceCurrent.Label    = $script:ce.EditName.Text.Trim()
    $script:ceCurrent.Props    = @($script:ce.EditProps.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $lks = New-Object System.Collections.ArrayList
    foreach ($row in $script:ce.LookupsPanel.Children) {
        $t = $row.Tag
        $chain = $null
        $url = ''
        if ($t.Chk.IsChecked) {
            $chain = New-Object System.Collections.ArrayList
            foreach ($sr in $t.StepsHost.Children) {
                $st = $sr.Tag
                [void]$chain.Add([ordered]@{ Url = $st.Url.Text.Trim(); Extract = $st.Extract.Text.Trim() })
            }
        } else {
            $url = $t.Url.Text.Trim()
        }
        [void]$lks.Add([ordered]@{
            Label      = $t.Label.Text.Trim()
            Url        = $url
            ValueHint  = $t.Hint.Text.Trim()
            ValueLabel = $t.VLabel.Text.Trim()
            Chain      = $chain
        })
    }
    $script:ceCurrent.Lookups = $lks
}

function Ce-SelectQuery {
    param($Q)
    Ce-CommitForm
    $script:ceCurrent = $Q
    Ce-LoadForm $Q
    Ce-BuildList
    Ce-SetStatus ''
}

function Ce-NewQuery {
    Ce-CommitForm
    $cat = $script:ce.EditCategory.Text.Trim()
    if (-not $cat) { $existing = Ce-DistinctCategories; $cat = if ($existing.Count) { $existing[0] } else { 'New category' } }
    $q = [ordered]@{
        Category = $cat; Label = 'New query'; Note = $null
        Props = @()
        Lookups = ([System.Collections.ArrayList]@([ordered]@{ Label = 'By value'; Url = ''; ValueHint = ''; ValueLabel = '' }))
    }
    [void]$script:ceQueries.Add($q)
    $script:ceCurrent = $q
    Ce-LoadForm $q
    Ce-BuildList
    $script:ce.EditName.Focus(); $script:ce.EditName.SelectAll()
    Ce-SetStatus ''
}

# Deep-copy a query model so editing the clone doesn't mutate the original.
function Ce-CloneQueryObj {
    param($Q)
    $lks = New-Object System.Collections.ArrayList
    foreach ($l in $Q.Lookups) {
        $chain = $null
        if ($l['Chain']) {
            $chain = New-Object System.Collections.ArrayList
            foreach ($s in $l['Chain']) { [void]$chain.Add([ordered]@{ Url = $s['Url']; Extract = $s['Extract'] }) }
        }
        [void]$lks.Add([ordered]@{ Label = $l['Label']; Url = $l['Url']; ValueHint = $l['ValueHint']; ValueLabel = $l['ValueLabel']; Chain = $chain })
    }
    [ordered]@{ Category = $Q['Category']; Label = $Q['Label']; Note = $Q['Note']; Props = @($Q['Props']); Lookups = $lks }
}

function Ce-CloneQuery {
    if (-not $script:ceCurrent) { return }
    Ce-CommitForm
    $clone = Ce-CloneQueryObj $script:ceCurrent
    $clone.Label = "$($script:ceCurrent.Label) (clone)"
    $idx = $script:ceQueries.IndexOf($script:ceCurrent)
    if ($idx -ge 0) { $script:ceQueries.Insert($idx + 1, $clone) } else { [void]$script:ceQueries.Add($clone) }
    $script:ceCurrent = $clone
    Ce-LoadForm $clone
    Ce-BuildList
    $script:ce.EditName.Focus(); $script:ce.EditName.SelectAll()
    Ce-SetStatus ''
}

function Ce-DeleteQuery {
    if (-not $script:ceCurrent) { return }
    $script:ceQueries.Remove($script:ceCurrent)
    $script:ceCurrent = if ($script:ceQueries.Count) { $script:ceQueries[0] } else { $null }
    Ce-LoadForm $script:ceCurrent
    Ce-BuildList
    Ce-SetStatus ''
}

# ---- validation + save ----------------------------------------------------
function Ce-Validate {
    if ($script:ceQueries.Count -eq 0) { return 'Add at least one query before saving.' }
    foreach ($q in $script:ceQueries) {
        $label = if ($q.Label) { $q.Label } else { '(unnamed)' }
        if (-not $q.Category) { return "Query '$label' needs a category." }
        if (-not $q.Label)    { return "A query in '$($q.Category)' has no name." }
        if ($q.Lookups.Count -eq 0) { return "Query '$label' needs at least one lookup." }
        foreach ($l in $q.Lookups) {
            if (-not $l.Label) { return "A lookup in '$label' has no name." }
            if ($l.Chain) {
                $steps = @($l.Chain)
                if ($steps.Count -lt 2) { return "Lookup '$($l.Label)' in '$label' is chained but needs at least 2 steps." }
                for ($si = 0; $si -lt $steps.Count; $si++) {
                    if (-not $steps[$si]['Url']) { return "Lookup '$($l.Label)' in '$label': step $($si+1) has no URL." }
                    if ($si -lt ($steps.Count - 1) -and -not $steps[$si]['Extract']) { return "Lookup '$($l.Label)' in '$label': step $($si+1) needs an Extract path." }
                }
            } elseif (-not $l.Url) { return "Lookup '$($l.Label)' in '$label' has no Graph URL." }
        }
    }
    $null
}

function Ce-BuildRoot {
    $outCats = @()
    foreach ($cn in Ce-DistinctCategories) {
        $qs = @()
        foreach ($q in @($script:ceQueries | Where-Object { $_.Category -eq $cn })) {
            $olks = @()
            foreach ($l in $q.Lookups) {
                $lk = [ordered]@{ Label = $l.Label }
                if ($l.ValueLabel) { $lk.ValueLabel = $l.ValueLabel }
                if ($l.ValueHint)  { $lk.ValueHint  = $l.ValueHint }
                $chain = $l.Chain
                if ($chain) {
                    $steps = @($chain)
                    $outSteps = @()
                    for ($si = 0; $si -lt $steps.Count; $si++) {
                        $step = [ordered]@{ Url = $steps[$si]['Url'] }
                        # Extract only matters for non-final steps.
                        if ($si -lt ($steps.Count - 1) -and $steps[$si]['Extract']) { $step.Extract = $steps[$si]['Extract'] }
                        $outSteps += $step
                    }
                    $lk.Chain = @($outSteps)
                } else {
                    $lk.Url = $l.Url
                }
                $olks += $lk
            }
            $oq = [ordered]@{ Label = $q.Label }
            if ($q.Note) { $oq._note = $q.Note }
            $oq.Lookups = @($olks)
            $oq.Props   = @($q.Props)
            $qs += $oq
        }
        $outCats += [ordered]@{ Category = $cn; Queries = @($qs) }
    }
    [ordered]@{ _readme = (Get-AducksReadme); categories = @($outCats) }
}

function Ce-Save {
    Ce-CommitForm
    $err = Ce-Validate
    if ($err) { Ce-SetStatus $err 'BadBrush'; return }
    try {
        Save-AducksQueriesFile -Root (Ce-BuildRoot)
    } catch {
        Ce-SetStatus ("Could not save: {0}" -f $_.Exception.Message) 'BadBrush'; return
    }
    if ($script:ceOnSaved) { try { & $script:ceOnSaved } catch { } }
    $script:ceWin.Close()
}

function Show-ConfigEditor {
    param(
        [Parameter(Mandatory)] $Owner,
        [scriptblock] $OnSaved
    )
    $script:ceOnSaved = $OnSaved

    $script:ceWin = Import-Xaml (Join-Path $UiRoot 'ConfigEditor.xaml')
    $script:ceWin.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $UiRoot 'Theme.xaml')))
    $script:ceWin.Owner = $Owner
    Initialize-WindowChrome $script:ceWin

    $script:ce = @{}
    foreach ($n in @(
        'QueryListPanel','NewQueryButton','CloneQueryButton','EmptyHint','FieldsPanel',
        'EditCategory','EditName','EditProps','AddLookupButton','LookupsPanel',
        'DeleteQueryButton','EditorStatus','CancelButton','SaveButton'
    )) { $script:ce[$n] = $script:ceWin.FindName($n) }

    # Fresh flat model from disk (reflects any external edits).
    $script:ceQueries = New-Object System.Collections.ArrayList
    foreach ($c in (Reload-AducksCategories)) {
        foreach ($q in $c.Queries) {
            $lks = New-Object System.Collections.ArrayList
            foreach ($l in $q.Lookups) {
                # Normalise any Chain into an ArrayList of [ordered]@{Url;Extract}
                # so the whole model uses one consistent shape.
                $rawChain = Get-Prop $l 'Chain'
                $chain = $null
                if ($rawChain) {
                    $chain = New-Object System.Collections.ArrayList
                    foreach ($s in @($rawChain)) {
                        [void]$chain.Add([ordered]@{ Url = (Get-Prop $s 'Url'); Extract = (Get-Prop $s 'Extract') })
                    }
                }
                [void]$lks.Add([ordered]@{
                    Label = $l.Label; Url = (Get-Prop $l 'Url')
                    ValueHint = (Get-Prop $l 'ValueHint'); ValueLabel = (Get-Prop $l 'ValueLabel')
                    Chain = $chain
                })
            }
            [void]$script:ceQueries.Add([ordered]@{
                Category = $c.Category; Label = $q.Label; Note = (Get-Prop $q '_note')
                Props = @($q.Props); Lookups = $lks
            })
        }
    }
    $script:ceCurrent = if ($script:ceQueries.Count) { $script:ceQueries[0] } else { $null }

    $script:ce.NewQueryButton.Add_Click({ Ce-NewQuery })
    $script:ce.CloneQueryButton.Add_Click({ Ce-CloneQuery })
    $script:ce.DeleteQueryButton.Add_Click({ Ce-DeleteQuery })
    $script:ce.AddLookupButton.Add_Click({ Ce-AddLookupRow -Label '' -Url '' -Hint '' -VLabel '' })
    $script:ce.SaveButton.Add_Click({ Ce-Save })
    $script:ce.CancelButton.Add_Click({ $script:ceWin.Close() })

    Ce-BuildList
    Ce-LoadForm $script:ceCurrent
    [void]$script:ceWin.ShowDialog()
}
