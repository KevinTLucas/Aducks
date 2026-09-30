<#
.SYNOPSIS
    Aducks entry point. Loads modules + XAML, wires the UI, runs the app.
    Launched by Aducks.bat:  powershell -STA -File src\Main.ps1
#>

[CmdletBinding()]
param(
    # Show the signed-in UI without authenticating (for QA). Queries return
    # fake sample data instead of calling Graph.
    [switch] $Preview,
    # Open without taking focus (automated QA runs, so they can't catch the
    # user's typing).
    [switch] $NoActivate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesRoot = Join-Path $ScriptRoot 'modules'
$UiRoot      = Join-Path $ScriptRoot 'ui'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -Path (Join-Path $ScriptRoot 'lib\Newtonsoft.Json.dll')   # hardened JSON parse/format

# Native calls: DWM title-bar theming, and an explicit AppUserModelID so the
# taskbar shows this window's icon instead of PowerShell's host icon.
Add-Type -Namespace Aducks -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr CreateIcon(System.IntPtr hInstance, int w, int h, byte planes, byte bpp, byte[] andMask, byte[] xorMask);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hwnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
'@
try { [void][Aducks.Native]::SetCurrentProcessExplicitAppUserModelID('Aducks.GraphQueryBuilder') } catch { }

# ---------------------------------------------------------------- XAML
function Import-Xaml {
    param([Parameter(Mandatory)][string] $Path)
    [xml]$xaml = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
}

# Startup (config + modules + XAML) is the one place a failure can't reach the
# in-app error popup yet, so surface it as a MessageBox and exit cleanly.
try {
    . (Join-Path $ScriptRoot 'Config.ps1')
    $Config     = Get-AducksConfig
    $Categories = Get-AducksCategories

    $CdpModule   = Join-Path $ModulesRoot 'Cdp.psm1'
    $GraphModule = Join-Path $ModulesRoot 'Graph.psm1'   # re-imported inside the query runspace
    Import-Module (Join-Path $ModulesRoot 'Jwt.psm1')       -Force
    Import-Module $GraphModule -Force
    Import-Module (Join-Path $ModulesRoot 'AuthState.psm1') -Force
    Import-Module $CdpModule -Force

    . (Join-Path $ScriptRoot 'ConfigEditor.ps1')     # in-app query-catalog editor
    . (Join-Path $ScriptRoot 'SettingsEditor.ps1')   # in-app settings.json editor

    $window = Import-Xaml (Join-Path $UiRoot 'MainWindow.xaml')
    $window.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $UiRoot 'Theme.xaml')))
} catch {
    [System.Windows.MessageBox]::Show(
        ("Aducks could not start.`n`n{0}`n`nCheck config\settings.json and config\queries.json for errors." -f $_.Exception.Message),
        'Aducks - Startup error', 'OK', 'Error') | Out-Null
    return
}

$ui = @{}
foreach ($n in @(
    'SignedOutPanel','AuthenticateButton','PreviewButton','HomeStatusText','SignedInRoot',
    'LoginBackdrop','TitleBrush','SignedOutT','SignedOutS','AuthGlow','BrandBrush',
    'ProfileButton','PillAvatar','PillAvatarImg','PillAvatarInitials','PillNameText','ProfileCountText','ProfilePopup',
    'PopupTenantText','PopupTenantIdText','PopupObjectIdText','PopupAppText','CopyTenantIdButton','CopyObjectIdButton',
    'PopupAvatar','PopupAvatarImg','PopupAvatarInitials','PopupUserText','PopupEmailText','PopupAccountType',
    'PopupExpiresText','PopupRemainingText','PopupScopesPanel','ScopesCountText','ReauthButton','SignOutButton','CopyTokenButton','ProfileSettingsButton',
    'AdvancedToggle','StepAdvanced','AdvancedUrlBox','SettingsButton',
    'AdvancedSinglePanel','AdvancedChainPanel','AdvancedStepsHost','TopBar','BuilderCard',
    'CategoryLabel','QueryLabel','LookupLabel','CategoryCombo','ActionCombo','StepLookup','LookupCombo','StepValue','ValueLabel','ValueBox','ValueWatermark','RunButton',
    'PropsButton','PropsButtonText','PropsPopup','PropsSearch','PropsSearchWatermark','PropsList','PropsSelectAll','PropsClear',
    'ResultStatus','SearchBox','SearchWatermark','FindPrevButton','FindNextButton','FindCountText','CopyResultButton','LoadMoreButton',
    'ResultTree','ResultMessage','ExpandAllButton','CollapseAllButton',
    'ResultSpinner','SpinnerRotate','SpinnerText'
)) { $ui[$n] = $window.FindName($n) }

# ---------------------------------------------------------------- state
$state = New-AuthState
$script:capture        = $null
$script:lastRevalidate = Get-Date
$script:nextLink       = $null
$script:accum          = $null
$script:isCollection   = $false
$script:curQuery       = $null
$script:previewMode    = $false
$script:previewPage    = 0
$script:previewSelect  = @()      # Return Properties applied to preview data
$script:advancedMode   = $false
$script:resultText     = ''       # pretty JSON of the current result (for Copy)
$script:findTerm       = ''       # term the current tree match list was built for
$script:findMatches    = @()      # matching TreeViewItems for findTerm
$script:findPos        = -1       # index of the current match
$script:treeNodes      = @()      # flat @{Item;Text} list of every tree node (for search)
$script:queryRun       = $null    # in-flight background Graph request (@{PS;Handle;Runspace;Kind})
$script:popupClosedAt  = [datetime]::MinValue   # for pill re-click toggle
# Sent on every query; harmless on simple calls, and enables advanced
# $search / $filter / $count queries that some URLs use.
$script:queryHeaders   = @{ ConsistencyLevel = 'eventual' }

function Get-Brush { param($Key) $window.FindResource($Key) }

# Set the app icon + a dark OS title bar on any Aducks window (main + editors).
$script:AppIcon = $null
function Initialize-WindowChrome {
    param($Win)
    if (-not $script:AppIcon) {
        try {
            # Use the largest frame in the .ico so the taskbar downscales (crisp)
            # rather than upscaling the 16px frame (blurry).
            $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create((New-Object Uri (Join-Path $UiRoot 'AppIcon.ico')), 'None', 'OnLoad')
            $script:AppIcon = @($dec.Frames | Sort-Object PixelWidth -Descending)[0]
        } catch { }
    }
    if ($script:AppIcon) { try { $Win.Icon = $script:AppIcon } catch { } }
    $Win.Add_SourceInitialized({
        param($s, $e)
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $s).Handle
            if ($h -ne [IntPtr]::Zero) {
                $one = 1
                [void][Aducks.Native]::DwmSetWindowAttribute($h, 20, [ref]$one, 4)  # dark mode (Win11 / Win10 2004+)
                [void][Aducks.Native]::DwmSetWindowAttribute($h, 19, [ref]$one, 4)  # dark mode (older builds)
                # Win11 22000+: colour the title bar to match the app (near-invisible).
                # Title text is drawn in the same colour, so no label shows in the
                # bar while Title still names the window in the taskbar / Alt+Tab.
                # COLORREF is 0x00BBGGRR.
                $capt = 0x1B110C   # #0C111B (app backdrop)
                [void][Aducks.Native]::DwmSetWindowAttribute($h, 35, [ref]$capt, 4)  # DWMWA_CAPTION_COLOR
                [void][Aducks.Native]::DwmSetWindowAttribute($h, 36, [ref]$capt, 4)  # DWMWA_TEXT_COLOR (hidden)
                [void][Aducks.Native]::DwmSetWindowAttribute($h, 34, [ref]$capt, 4)  # DWMWA_BORDER_COLOR
            }
        } catch { }
    })
    # After the window is loaded (WPF has applied Window.Icon), replace only the
    # SMALL icon (title bar) with a transparent one, leaving the BIG icon
    # (taskbar) as the duck. WM_SETICON=0x80, ICON_SMALL=0.
    $Win.Add_Loaded({
        param($s, $e)
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $s).Handle
            if ($h -ne [IntPtr]::Zero) {
                $and = New-Object 'byte[]' 32; for ($i = 0; $i -lt 32; $i++) { $and[$i] = 0xFF }  # AND=1 -> transparent
                $xor = New-Object 'byte[]' 32                                                     # XOR=0
                $blank = [Aducks.Native]::CreateIcon([IntPtr]::Zero, 16, 16, 1, 1, $and, $xor)
                [void][Aducks.Native]::SendMessage($h, 0x80, [IntPtr]0, $blank)
            }
        } catch { }
    })
}

# Clipboard can throw if another process holds it open. Returns $true on success.
function Set-Clipboard-Safe { param([string]$Text)
    try { [System.Windows.Clipboard]::SetText($Text); $true } catch { $false }
}

# Copy an identifier and briefly flash the icon button to a checkmark.
function Copy-IdWithFlash { param($Button, [string]$Text)
    if (-not $Text -or $Text -eq '-') { return }
    if (Set-Clipboard-Safe $Text) {
        $script:copyFlashTimer.Stop()
        if ($script:copyFlashBtn) { $script:copyFlashBtn.Content = [char]0xE8C8 }   # restore previous
        $Button.Content = [char]0xE73E                                              # checkmark
        $script:copyFlashBtn = $Button
        $script:copyFlashTimer.Start()
    }
}

# StrictMode-safe optional property read (config objects vary by lookup).
function Get-Prop { param($Obj, [string]$Name)
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null }
}

# Query-builder step labels are fixed (not user-configurable).
function Set-StepLabels {
    $ui.CategoryLabel.Text = 'WHAT ARE YOU LOOKING FOR?'
    $ui.QueryLabel.Text    = 'WHAT DO YOU WANT TO SEE?'
    $ui.LookupLabel.Text   = 'HOW DO YOU WANT TO FIND IT?'
}

# ---------------------------------------------------------------- auth UI
function Set-HomeStatus {
    param([string] $Text, [string] $BrushKey = 'WarnBrush')
    $ui.HomeStatusText.Text = $Text
    $ui.HomeStatusText.Foreground = Get-Brush $BrushKey
}

function New-DriftAnim {
    param($From, $To, $Seconds)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From; $a.To = $To
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($Seconds))
    $a.AutoReverse = $true
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ease = New-Object System.Windows.Media.Animation.SineEase; $ease.EasingMode = 'EaseInOut'
    $a.EasingFunction = $ease
    $a
}

function New-IntroAnim {
    param($From, $To, $Seconds)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From; $a.To = $To
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($Seconds))
    $ease = New-Object System.Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
    $a.EasingFunction = $ease
    $a
}

function New-PointAnim {
    param($FromX, $ToX, $Seconds)
    $a = New-Object System.Windows.Media.Animation.PointAnimation
    $a.From = New-Object System.Windows.Point ($FromX, 0)
    $a.To   = New-Object System.Windows.Point ($ToX, 0)
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($Seconds))
    $a.AutoReverse = $true
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ease = New-Object System.Windows.Media.Animation.SineEase; $ease.EasingMode = 'EaseInOut'
    $a.EasingFunction = $ease
    $a
}

$YP = [System.Windows.Media.TranslateTransform]::YProperty
$OP = [System.Windows.UIElement]::OpacityProperty

# Background is static; the only login animations are the wordmark shine, the
# button glow pulse, and the one-shot intro fade/rise.
function Start-LoginAnimations {
    # Shine sweeping across the wordmark.
    $ui.TitleBrush.BeginAnimation([System.Windows.Media.LinearGradientBrush]::StartPointProperty, (New-PointAnim -0.8 0.9 3.6))
    $ui.TitleBrush.BeginAnimation([System.Windows.Media.LinearGradientBrush]::EndPointProperty,   (New-PointAnim  0.2 1.9 3.6))

    if ($ui.AuthGlow) {
        $ui.AuthGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, (New-DriftAnim 14 44 1.9))
        $ui.AuthGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty,   (New-DriftAnim 0.25 0.9 1.9))
    }

    # Intro: fade + rise + gentle scale settle each time the login screen appears.
    $ui.SignedOutPanel.BeginAnimation($OP, (New-IntroAnim 0 1 0.9))
    $ui.SignedOutT.BeginAnimation($YP, (New-IntroAnim 26 0 0.9))
    $ui.SignedOutS.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-IntroAnim 0.96 1 0.9))
    $ui.SignedOutS.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-IntroAnim 0.96 1 0.9))
}

function Stop-LoginAnimations {
    $ui.TitleBrush.BeginAnimation([System.Windows.Media.LinearGradientBrush]::StartPointProperty, $null)
    $ui.TitleBrush.BeginAnimation([System.Windows.Media.LinearGradientBrush]::EndPointProperty, $null)
    if ($ui.AuthGlow) {
        $ui.AuthGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, $null)
        $ui.AuthGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $null)
    }
}

# The signed-in top-bar wordmark shines with the same sweep as the login title.
function Start-BrandAnimation {
    $ui.BrandBrush.BeginAnimation([System.Windows.Media.LinearGradientBrush]::StartPointProperty, (New-PointAnim -0.8 0.9 3.6))
    $ui.BrandBrush.BeginAnimation([System.Windows.Media.LinearGradientBrush]::EndPointProperty,   (New-PointAnim  0.2 1.9 3.6))
}

function Show-SignedOut {
    $script:previewMode = $false
    $ui.SignedOutPanel.Visibility = 'Visible'
    $ui.LoginBackdrop.Visibility  = 'Visible'
    $ui.SignedInRoot.Visibility   = 'Collapsed'
    $ui.ProfilePopup.IsOpen = $false
    $ui.AuthenticateButton.IsEnabled = $true
    $ui.AuthenticateButton.Content   = 'Sign in with Microsoft'
    $ui.ReauthButton.IsEnabled = $true
    $ui.ReauthButton.Content   = 'Reauthenticate'
    Start-LoginAnimations
}

function Enter-Preview {
    # Realistic-but-fake identity so the UI matches the real product for demos and
    # README screenshots. No real token is ever involved (AccessToken stays null).
    $script:previewMode = $true
    $state.IsAuthenticated = $true
    $state.AccessToken = $null
    $state.User       = [PSCustomObject]@{ displayName = 'John Smith'; userPrincipalName = 'john.smith@contoso.com'; mail = 'john.smith@contoso.com' }
    $state.ExpiresAt  = (Get-Date).AddMinutes(59)
    $state.Scopes     = @('User.Read','User.ReadBasic.All','Directory.Read.All','Group.Read.All','GroupMember.Read.All','AuditLog.Read.All','openid','profile','email')
    $state.TenantName = 'Contoso Corporation'
    $state.Photo      = $null
    $state.Jwt        = [PSCustomObject]@{ Payload = [PSCustomObject]@{
        tid             = '3c7e9f21-4a8b-4c6d-9e1f-5b2a7d0c3e44'
        oid             = '9f5b1c8e-2d47-4a93-b6f0-1e8c7a45d902'
        app_displayname = 'Graph Explorer'
    } }
    Set-HomeStatus -Text ''
    Clear-Results
    Show-SignedIn   # populates the countdown from ExpiresAt
    $script:timer.Start()   # ticks the countdown (revalidation is skipped in preview)
}

# Empty the results panel and cancel any running query (sign-out, or switching
# between preview and a real session, so one session never shows another's data).
function Clear-Results {
    if ($script:queryRun) {
        $script:queryTimer.Stop()
        # ponytail: fire-and-forget stop; the orphaned runspace is left for GC.
        try { [void]$script:queryRun.PS.BeginStop($null, $null) } catch { }
        $script:queryRun = $null
        Stop-Spinner
        $ui.RunButton.IsEnabled = $true
    }
    $script:accum = $null; $script:nextLink = $null; $script:resultText = ''
    Set-ResultMessage ''
    $ui.ResultStatus.Text = 'Results'
    $ui.LoadMoreButton.Visibility = 'Collapsed'
}

function Update-Countdown {
    $remaining = Get-RemainingLifetime -State $state
    $ui.ProfileCountText.Text   = ('{0:hh\:mm\:ss} left' -f $remaining)
    $ui.PopupRemainingText.Text = ('{0:hh\:mm\:ss}' -f $remaining)
    $key = if ($remaining.TotalMinutes -lt 2) { 'BadBrush' } elseif ($remaining.TotalMinutes -lt 10) { 'WarnBrush' } else { 'GoodBrush' }
    $ui.ProfileCountText.Foreground   = Get-Brush $key
    $ui.PopupRemainingText.Foreground = Get-Brush $key
}

function Get-Initials {
    param([string]$Name)
    if (-not $Name) { return '?' }
    $clean = $Name -replace '[,]', ' '
    $parts = @($clean -split '\s+' | Where-Object { $_ })
    if ($parts.Count -ge 2) { return ($parts[0].Substring(0,1) + $parts[1].Substring(0,1)).ToUpper() }
    if ($parts.Count -eq 1) { return $parts[0].Substring(0, [Math]::Min(2, $parts[0].Length)).ToUpper() }
    '?'
}

# Photo goes into an Image clipped by an EllipseGeometry (smooth, antialiased
# circle) instead of filling the Ellipse with an ImageBrush (which renders a
# jagged edge). The Ellipse stays as the coloured fallback behind the initials.
function Set-Avatar {
    param($Ellipse, $Image, $Initials, [string]$InitialsText, $Bytes)
    $Initials.Text = $InitialsText
    if ($Bytes) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.CacheOption  = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.StreamSource = New-Object System.IO.MemoryStream (, [byte[]]$Bytes)
            $bmp.EndInit(); $bmp.Freeze()
            $Image.Source = $bmp
            $Image.Visibility = 'Visible'
            $Initials.Visibility = 'Collapsed'
            return
        } catch { }
    }
    $Image.Source = $null
    $Image.Visibility = 'Collapsed'
    $Ellipse.Fill = Get-Brush 'AccentBrush2'
    $Initials.Visibility = 'Visible'
}

function Set-ScopeChips {
    $ui.PopupScopesPanel.Children.Clear()
    $scopes = @($state.Scopes)
    $ui.ScopesCountText.Text = if ($scopes.Count) { "$($scopes.Count)" } else { '' }
    if (-not $scopes.Count) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '(none in token)'; $tb.Foreground = Get-Brush 'MutedBrush'; $tb.FontSize = 12
        [void]$ui.PopupScopesPanel.Children.Add($tb); return
    }
    foreach ($s in $scopes) {
        $chip = New-Object System.Windows.Controls.Border
        $chip.Background      = Get-Brush 'PanelBrush2'
        $chip.BorderBrush     = Get-Brush 'BorderBrush2'
        $chip.BorderThickness = New-Object System.Windows.Thickness 1
        $chip.CornerRadius    = New-Object System.Windows.CornerRadius 4
        $chip.Padding         = New-Object System.Windows.Thickness (7, 2, 7, 2)
        $chip.Margin          = New-Object System.Windows.Thickness (0, 0, 5, 5)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $s; $t.FontSize = 11; $t.Foreground = Get-Brush 'TextBrush'
        $chip.Child = $t
        [void]$ui.PopupScopesPanel.Children.Add($chip)
    }
}

function Show-SignedIn {
    Stop-LoginAnimations
    $ui.SignedOutPanel.Visibility = 'Collapsed'
    $ui.LoginBackdrop.Visibility  = 'Collapsed'
    $ui.SignedInRoot.Visibility   = 'Visible'
    Start-BrandAnimation

    $name = '-'; $email = '-'
    if ($state.User) {   # Get-Prop: /me may omit fields (StrictMode-safe)
        $dn = Get-Prop $state.User 'displayName'; if ($dn) { $name = $dn }
        $email = Get-Prop $state.User 'userPrincipalName'; if (-not $email) { $email = Get-Prop $state.User 'mail' }
        if (-not $email) { $email = '-' }
    }
    $initials = Get-Initials $name

    $ui.PopupUserText.Text   = $name
    $ui.PopupEmailText.Text  = $email
    $ui.PillNameText.Text    = $name
    $ui.PopupTenantText.Text = if ($state.TenantName) { $state.TenantName } else { '(tenant unknown)' }

    # Identifiers + token source, pulled from the decoded JWT claims.
    $payload = if ($state.Jwt) { $state.Jwt.Payload } else { $null }
    $tid = if ($payload) { Get-Prop $payload 'tid' } else { $null }
    $oid = if ($payload) { Get-Prop $payload 'oid' } else { $null }
    $app = if ($payload) { Get-Prop $payload 'app_displayname' } else { $null }

    $ui.PopupAccountType.Text = if ($tid) { 'Work account' } else { 'Personal account' }
    $ui.PopupTenantIdText.Text = if ($tid) { $tid } else { '-' }
    $ui.PopupObjectIdText.Text = if ($oid) { $oid } else { '-' }
    $ui.PopupAppText.Text = if ($app) { "Signed in via $app" } else { 'Signed in via Microsoft Graph Explorer' }

    Set-Avatar $ui.PillAvatar  $ui.PillAvatarImg  $ui.PillAvatarInitials  $initials $state.Photo
    Set-Avatar $ui.PopupAvatar $ui.PopupAvatarImg $ui.PopupAvatarInitials $initials $state.Photo

    $ui.PopupExpiresText.Text = if ($state.ExpiresAt) {
        'Expires ' + $state.ExpiresAt.ToString('h:mm tt') + ' on ' + $state.ExpiresAt.ToString('ddd, MMM d, yyyy')
    } else { 'Expiry unknown' }
    Set-ScopeChips
    Update-Countdown
}

function Invoke-SignOut {
    param([string] $Reason)
    $script:timer.Stop()
    if ($script:capture) {
        # Abandon an in-flight sign-in, or it would sign the user back in later.
        # Stopping runs the capture's finally block (closes the browser).
        $script:captureTimer.Stop()
        try { [void]$script:capture.PS.BeginStop($null, $null) } catch { }
        $script:capture = $null
    }
    Clear-AuthState -State $state | Out-Null
    Clear-Results
    Show-SignedOut
    if ($Reason) { Set-HomeStatus -Text $Reason }
}

# ---------------------------------------------------------------- countdown / revalidation
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds($Config.CountdownIntervalMs)
$script:timer.Add_Tick({
    if (-not $state.IsAuthenticated) { $script:timer.Stop(); return }
    # Preview's fake session just rolls over instead of signing you out.
    if ($script:previewMode -and (Test-AuthStateExpired -State $state -SkewSec $Config.ExpirySkewSec)) {
        $state.ExpiresAt = (Get-Date).AddMinutes(59); Show-SignedIn   # refreshes the "Expires" line
    }
    if (Test-AuthStateExpired -State $state -SkewSec $Config.ExpirySkewSec) {
        Invoke-SignOut -Reason 'Token expired - please authenticate again.'; return
    }
    Update-Countdown
    if (-not $script:previewMode -and $Config.RevalidateIntervalSec -gt 0 -and ((Get-Date) - $script:lastRevalidate).TotalSeconds -ge $Config.RevalidateIntervalSec) {
        $script:lastRevalidate = Get-Date
        if ((Get-GraphMe -AccessToken $state.AccessToken -MeUrl $Config.GraphMeUrl).Unauthorized) {
            Invoke-SignOut -Reason 'Graph rejected the token (401) - please authenticate again.'
        }
    }
})

# ---------------------------------------------------------------- capture (background runspace)
function Start-CaptureAsync {
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($CdpModulePath, $Config)
        Import-Module $CdpModulePath -Force
        Invoke-GraphTokenCapture -Config $Config
    }).AddArgument($CdpModule).AddArgument($Config)
    $script:capture = @{ PS = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs }
}

function Stop-CaptureAsync {
    if (-not $script:capture) { return }
    try { $script:capture.PS.Dispose() } catch { }
    try { $script:capture.Runspace.Dispose() } catch { }
    $script:capture = $null
}

function Start-Authentication {
    if ($script:capture) { return }   # a sign-in is already in progress
    if ($ui.SignedOutPanel.Visibility -eq 'Visible') {
        $ui.AuthenticateButton.IsEnabled = $false
        $ui.AuthenticateButton.Content   = 'Waiting for sign-in...'
        Set-HomeStatus -Text 'Opening Microsoft Graph Explorer. Complete sign-in in the browser...'
    } else {
        $ui.ReauthButton.IsEnabled = $false
        $ui.ReauthButton.Content   = 'Waiting for sign-in...'
    }
    try { Start-CaptureAsync; $script:captureTimer.Start() }
    catch {
        $ui.AuthenticateButton.IsEnabled = $true
        $ui.AuthenticateButton.Content   = 'Sign in with Microsoft'
        Show-AuthFailure ("Could not start capture: {0}" -f $_.Exception.Message)
    }
}

# A failed sign-in. From Reauthenticate (already signed in, or in preview) the
# current session is still valid, so keep it and just report; otherwise show the
# error on the sign-in screen.
function Show-AuthFailure {
    param([string] $Message)
    $ui.ReauthButton.IsEnabled = $true
    $ui.ReauthButton.Content   = 'Reauthenticate'
    if ($ui.SignedInRoot.Visibility -eq 'Visible') {
        [void][System.Windows.MessageBox]::Show($window, $Message, 'Aducks - sign-in failed', 'OK', 'Warning')
    } else {
        Show-SignedOut
        Set-HomeStatus -Text $Message -BrushKey 'BadBrush'
    }
}

$script:captureTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:captureTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:captureTimer.Add_Tick({
    if (-not $script:capture -or -not $script:capture.Handle.IsCompleted) { return }
    $script:captureTimer.Stop()
    $token = $null; $err = $null
    try {
        $result = $script:capture.PS.EndInvoke($script:capture.Handle)
        if ($script:capture.PS.HadErrors -and $script:capture.PS.Streams.Error.Count) { $err = $script:capture.PS.Streams.Error[0].ToString() }
        else { $a = @($result); if ($a.Count) { $token = $a[-1] } }   # empty -> "no token captured"
    } catch {
        # EndInvoke wraps the runspace's error ("Exception calling EndInvoke...");
        # show the real reason underneath.
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        $err = $ex.Message
    } finally { Stop-CaptureAsync }

    if ($err -or -not $token) {
        Show-AuthFailure ("Authentication failed: {0}" -f $(if ($err) { $err } else { 'no token captured' }))
        return
    }
    Complete-Authentication -Token ([string]$token)
})

function Complete-Authentication {
    param([Parameter(Mandatory)][string] $Token)
    # Decoding throws before $state is touched, so a bad token keeps any current session.
    try { Set-AuthStateToken -State $state -AccessToken $Token | Out-Null }
    catch { Show-AuthFailure 'Sign-in returned a token Aducks could not read. Please try again.'; return }

    if ($script:previewMode) {
        # Coming from Preview: drop the sample identity and sample results so a
        # failed /me or /organization can't leave "John Smith" on a real session.
        $state.User = $null; $state.TenantName = $null; $state.Photo = $null
        Clear-Results
    }

    $me = Get-GraphMe -AccessToken $Token -MeUrl $Config.GraphMeUrl
    if ($me.Ok) { Set-AuthStateUser -State $state -User $me.Data | Out-Null }
    elseif ($me.Unauthorized) { Invoke-SignOut -Reason 'Graph rejected the captured token (401).'; return }

    # A real token now: leave preview mode (Reauthenticate from Preview), so
    # queries hit Graph instead of returning sample data.
    $script:previewMode = $false
    $ui.ReauthButton.IsEnabled = $true
    $ui.ReauthButton.Content   = 'Reauthenticate'

    # Best-effort account-widget extras (never block sign-in on these).
    try {
        $org = Invoke-GraphRequest -AccessToken $Token -Uri "$($Config.GraphV1)/organization?`$select=displayName"
        if ($org.Ok -and $org.Data.value -and $org.Data.value.Count -gt 0) { $state.TenantName = $org.Data.value[0].displayName }
    } catch { }
    try { $state.Photo = Get-GraphPhoto -AccessToken $Token -Base $Config.GraphV1 } catch { }

    Set-HomeStatus -Text ''
    $script:lastRevalidate = Get-Date
    Show-SignedIn
    $script:timer.Start()
}

# ---------------------------------------------------------------- query UI
# Re-read queries.json after the catalog editor saves and rebuild the dropdowns,
# keeping the selected category index where possible.
function Reload-Catalog {
    $script:Categories = Reload-AducksCategories
    $sel = $ui.CategoryCombo.SelectedIndex
    $ui.CategoryCombo.Items.Clear()
    foreach ($c in $script:Categories) { [void]$ui.CategoryCombo.Items.Add($c.Category) }
    if ($sel -ge 0 -and $sel -lt @($script:Categories).Count) { $ui.CategoryCombo.SelectedIndex = $sel }
    else { $ui.CategoryCombo.SelectedIndex = 0 }
}

# Re-read settings.json after the settings editor saves and rebuild the merged
# config (browser, sign-in selector, login wait apply on the next sign-in).
function Reload-Settings {
    Reload-AducksSettings | Out-Null
    $script:Config = Get-AducksConfig
}

function Set-Category {
    if ($ui.CategoryCombo.SelectedIndex -lt 0) { return }
    $cat = $Categories[$ui.CategoryCombo.SelectedIndex]
    $ui.ActionCombo.Items.Clear()
    foreach ($q in $cat.Queries) { [void]$ui.ActionCombo.Items.Add($q.Label) }
    $ui.ActionCombo.SelectedIndex = 0   # triggers Set-Action
}

function Set-Action {
    if ($ui.CategoryCombo.SelectedIndex -lt 0 -or $ui.ActionCombo.SelectedIndex -lt 0) { return }
    $script:curQuery = $Categories[$ui.CategoryCombo.SelectedIndex].Queries[$ui.ActionCombo.SelectedIndex]

    $ui.LookupCombo.Items.Clear()
    foreach ($l in $script:curQuery.Lookups) { [void]$ui.LookupCombo.Items.Add($l.Label) }
    $ui.LookupCombo.SelectedIndex = 0   # triggers Update-ValueStep

    # Step 3 "how to find it" only matters when there's more than one way.
    $ui.StepLookup.Visibility = if ($script:curQuery.Lookups.Count -gt 1) { 'Visible' } else { 'Collapsed' }
    Update-ValueStep

    # Return-properties multi-select
    $ui.PropsSearch.Text = ''
    $ui.PropsList.Children.Clear()
    # Default = nothing checked -> no $select -> Graph returns its default fields.
    foreach ($p in $script:curQuery.Props) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $p; $cb.IsChecked = $false
        $cb.Style = Get-Brush 'Check'
        $cb.Add_Click({ Update-PropsButton })
        [void]$ui.PropsList.Children.Add($cb)
    }
    Update-PropsButton
}

function Get-CurrentLookup {
    if (-not $script:curQuery -or $ui.LookupCombo.SelectedIndex -lt 0) { return $null }
    $script:curQuery.Lookups[$ui.LookupCombo.SelectedIndex]
}

# Show the Value step only when the URL needs input ({value}). Its label and
# placeholder are config-driven per lookup:
#   ValueLabel - overrides the label above the box
#   ValueHint  - grey placeholder text inside the box
function Update-ValueStep {
    $lk = Get-CurrentLookup
    if (-not $lk) { return }
    # For a chain, the user's input feeds step 1, so use its Url to decide the box.
    $chain = Get-Prop $lk 'Chain'
    $url = if ($chain) { Get-Prop (@($chain)[0]) 'Url' } else { Get-Prop $lk 'Url' }
    if (-not ($url -and ($url -match '\{value\}'))) {
        $ui.StepValue.Visibility = 'Collapsed'
        Update-AdvancedUrl
        return
    }
    $label = Get-Prop $lk 'ValueLabel'
    if (-not $label) { $label = "VALUE - {0}" -f $lk.Label }
    $ui.ValueLabel.Text = $label.ToUpper()

    $hint = Get-Prop $lk 'ValueHint'; if (-not $hint) { $hint = '' }
    $ui.ValueWatermark.Text = $hint
    Update-ValueWatermark
    $ui.StepValue.Visibility = 'Visible'
    Update-AdvancedUrl
}

function Update-ValueWatermark {
    $ui.ValueWatermark.Visibility = if ([string]::IsNullOrEmpty($ui.ValueBox.Text)) { 'Visible' } else { 'Collapsed' }
}

# In Advanced mode, mirror the builder's URL into the editable box so the user
# sees exactly what will be sent and can tweak it. Changing any builder control
# re-syncs; manual edits stick until the next builder change.
# One read-only step box in the Advanced chain preview.
function Add-AdvancedStepBox {
    param([string] $Caption, [string] $Url, [string] $Extract)
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Caption; $lbl.Style = Get-Brush 'FieldLabel'; $lbl.Margin = '0,8,0,2'
    [void]$ui.AdvancedStepsHost.Children.Add($lbl)

    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $Url; $tb.IsReadOnly = $true
    $tb.Background = Get-Brush 'PanelBrush2'; $tb.Foreground = Get-Brush 'TextBrush'
    $tb.BorderBrush = Get-Brush 'BorderBrush2'; $tb.BorderThickness = 1
    $tb.FontFamily = 'Consolas, Cascadia Mono, monospace'; $tb.FontSize = 12; $tb.Padding = 8
    $tb.TextWrapping = 'Wrap'
    [void]$ui.AdvancedStepsHost.Children.Add($tb)

    if ($Extract) {
        $note = New-Object System.Windows.Controls.TextBlock
        $note.Text = "|  extract  $Extract  ->  feeds the next step's {value}"
        $note.Foreground = Get-Brush 'MutedBrush'; $note.FontSize = 11; $note.Margin = '2,3,0,0'
        [void]$ui.AdvancedStepsHost.Children.Add($note)
    }
}

function Update-AdvancedUrl {
    if (-not $script:advancedMode) { return }
    $lk = Get-CurrentLookup; if (-not $lk) { return }
    $chain = Get-Prop $lk 'Chain'
    if ($chain) {
        # Chained lookup: one read-only box per step. The last step carries
        # $select (Return Properties) and is the result that's shown.
        $ui.AdvancedSinglePanel.Visibility = 'Collapsed'
        $ui.AdvancedChainPanel.Visibility  = 'Visible'
        $ui.AdvancedStepsHost.Children.Clear()
        $steps = @($chain)
        $val = $ui.ValueBox.Text.Trim(); if (-not $val) { $val = '{value}' }
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $isLast  = ($i -eq $steps.Count - 1)
            $stepVal = if ($i -eq 0) { $val } else { "<id from step $i>" }
            $u = [string](Get-Prop $steps[$i] 'Url') -replace '\{value\}', $stepVal
            if ($u -notmatch '^https?://') { $u = "$($Config.GraphV1)/$u" }
            if ($isLast) {
                $sel = Get-CheckedProps
                if ($sel) { $sep = if ($u.Contains('?')) { '&' } else { '?' }; $u = "$u$sep`$select=$sel" }
            }
            $caption = if ($isLast) { "STEP $($i + 1)   (result shown)" } else { "STEP $($i + 1)" }
            $ex = if (-not $isLast) { [string](Get-Prop $steps[$i] 'Extract') } else { '' }
            Add-AdvancedStepBox -Caption $caption -Url $u -Extract $ex
        }
    } else {
        $ui.AdvancedChainPanel.Visibility  = 'Collapsed'
        $ui.AdvancedSinglePanel.Visibility = 'Visible'
        $ui.AdvancedUrlBox.IsReadOnly = $false
        try {
            $ui.AdvancedUrlBox.Text = New-GraphQueryUri -Url (Get-Prop $lk 'Url') -Value $ui.ValueBox.Text.Trim() `
                                                        -SelectCsv (Get-CheckedProps) -Base $Config.GraphV1
        } catch { }
    }
}

function Get-PropCheckBoxes { @($ui.PropsList.Children) }

# Comma-joined checked field names, or '' when none are checked (the "Default"
# state). Must stay null-safe: @(...) keeps it an array so a zero-checked result
# never hits ($null).Content, which throws under StrictMode.
function Get-CheckedProps {
    @(Get-PropCheckBoxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Content }) -join ','
}

function Update-PropsButton {
    $all = @(Get-PropCheckBoxes)
    $sel = @($all | Where-Object { $_.IsChecked })
    if ($sel.Count -eq 0)             { $ui.PropsButtonText.Text = 'Default' }
    elseif ($sel.Count -eq $all.Count) { $ui.PropsButtonText.Text = 'All properties' }
    else                              { $ui.PropsButtonText.Text = "$($sel.Count) of $($all.Count) selected" }
    Update-AdvancedUrl
}

function Set-AllProps {
    param([bool] $Checked)
    foreach ($cb in Get-PropCheckBoxes) { $cb.IsChecked = $Checked }
    Update-PropsButton
}

function Update-PropsFilter {
    $term = $ui.PropsSearch.Text
    $ui.PropsSearchWatermark.Visibility = if ([string]::IsNullOrEmpty($term)) { 'Visible' } else { 'Collapsed' }
    foreach ($cb in Get-PropCheckBoxes) {
        $cb.Visibility = if (-not $term -or "$($cb.Content)".IndexOf($term, [System.StringComparison]::InvariantCultureIgnoreCase) -ge 0) { 'Visible' } else { 'Collapsed' }
    }
}

# ---------------------------------------------------------------- JSON tree view
$script:TreeBrush = @{
    Key   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x6F, 0xB6, 0xFF))  # keys
    Str   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x5F, 0xD0, 0x8A))  # strings
    Num   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF2, 0xB2, 0x4A))  # numbers
    Lit   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xC0, 0x8C, 0xF0))  # true/false/null
    Muted = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x85, 0x92, 0xA8))  # {N} / [N] summary
}
foreach ($b in $script:TreeBrush.Values) { $b.Freeze() }

# Text a node copies as its "value": a leaf's raw value (strings unquoted),
# or pretty JSON for an object/array.
function Get-TokenCopyText {
    param($Token)   # [Newtonsoft.Json.Linq.JToken]
    if ($null -eq $Token) { return '' }
    if ($Token -is [Newtonsoft.Json.Linq.JValue]) {
        # Strings raw (dates stay strings: Show-Result parses with DateParseHandling=None);
        # numbers / true / false / null as their JSON literal.
        if ($Token.Type -eq [Newtonsoft.Json.Linq.JTokenType]::String) { return [string]$Token.Value }
        return $Token.ToString([Newtonsoft.Json.Formatting]::None)
    }
    $Token.ToString([Newtonsoft.Json.Formatting]::Indented)
}

# Right-click menu shared by every tree row (PlacementTarget = the row's header,
# whose Tag is its JToken). The first item's label adapts to what was clicked.
$script:TreeMenu = New-Object System.Windows.Controls.ContextMenu
$miCopyVal = New-Object System.Windows.Controls.MenuItem
$miCopyVal.InputGestureText = 'Ctrl+C'
$miCopyVal.Add_Click({ [void](Set-Clipboard-Safe (Get-TokenCopyText $script:TreeMenu.PlacementTarget.Tag)) })
$miCopyParent = New-Object System.Windows.Controls.MenuItem
$miCopyParent.Header = 'Copy parent object'
$miCopyParent.Add_Click({
    $tok = $script:TreeMenu.PlacementTarget.Tag
    $obj = $tok.Parent; if ($obj -is [Newtonsoft.Json.Linq.JProperty]) { $obj = $obj.Parent }
    [void](Set-Clipboard-Safe (Get-TokenCopyText $obj))
})
[void]$script:TreeMenu.Items.Add($miCopyVal)
[void]$script:TreeMenu.Items.Add($miCopyParent)
$script:TreeMenu.Add_Opened({
    $tok = $script:TreeMenu.PlacementTarget.Tag
    $miCopyVal.Header = if ($tok -is [Newtonsoft.Json.Linq.JObject]) { 'Copy object (JSON)' }
                        elseif ($tok -is [Newtonsoft.Json.Linq.JArray]) { 'Copy list (JSON)' }
                        else { 'Copy value' }
    # Only offered for a field inside an object (e.g. copy the whole user from its "mail" line).
    $p = $tok.Parent; if ($p -is [Newtonsoft.Json.Linq.JProperty]) { $p = $p.Parent }
    $miCopyParent.Visibility = if ($p -is [Newtonsoft.Json.Linq.JObject]) { 'Visible' } else { 'Collapsed' }
})

# A row: optional coloured key, then a coloured value/summary. Returns the panel.
function New-TreeHeader {
    param([string]$Key, [bool]$Leaf, [string]$ValueText, $ValueBrush, $Token)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $sp.Background = [System.Windows.Media.Brushes]::Transparent   # right-click hits the gaps too
    $sp.Tag = $Token; $sp.ContextMenu = $script:TreeMenu
    if ($null -ne $Key -and $Key -ne '') {
        $k = New-Object System.Windows.Controls.TextBlock
        $k.Text = if ($Leaf) { "$Key`: " } else { "$Key  " }
        $k.Foreground = $script:TreeBrush.Key
        [void]$sp.Children.Add($k)
    }
    $v = New-Object System.Windows.Controls.TextBlock
    $v.Text = $ValueText; $v.Foreground = $ValueBrush
    [void]$sp.Children.Add($v)
    $sp
}

# Colour for a Newtonsoft JValue leaf, keyed by its parsed JSON type.
function Get-JValueBrush {
    param($Token)   # [Newtonsoft.Json.Linq.JToken]
    switch ([int]$Token.Type) {
        6 { $script:TreeBrush.Num }   # Integer
        7 { $script:TreeBrush.Num }   # Float
        9 { $script:TreeBrush.Lit }   # Boolean
        10 { $script:TreeBrush.Lit }  # Null
        11 { $script:TreeBrush.Lit }  # Undefined
        default { $script:TreeBrush.Str }  # String / Date / Guid / Uri / TimeSpan / Bytes
    }
}

# Recursively add a node for a Newtonsoft JToken (labelled $Key) under $Owner.
function Add-JsonTree {
    param($Owner, [string]$Key, $Token)
    $tvi = New-Object System.Windows.Controls.TreeViewItem
    $tvi.Tag = $Token   # Ctrl+C on a selected node copies its value
    if ($Token -is [Newtonsoft.Json.Linq.JObject]) {
        $props = @($Token.Properties())
        $tvi.Header = New-TreeHeader -Key $Key -Leaf $false -ValueText ("{$($props.Count)}") -ValueBrush $script:TreeBrush.Muted -Token $Token
        foreach ($p in $props) { Add-JsonTree $tvi $p.Name $p.Value }
        $search = "$Key"
    } elseif ($Token -is [Newtonsoft.Json.Linq.JArray]) {
        $tvi.Header = New-TreeHeader -Key $Key -Leaf $false -ValueText ("[$($Token.Count)]") -ValueBrush $script:TreeBrush.Muted -Token $Token
        $i = 0; foreach ($it in $Token) { Add-JsonTree $tvi "$i" $it; $i++ }
        $search = "$Key"
    } else {
        # JValue: ToString(None) yields the exact JSON literal ("str", 5, true, null)
        $text = $Token.ToString([Newtonsoft.Json.Formatting]::None)
        $tvi.Header = New-TreeHeader -Key $Key -Leaf $true -ValueText $text -ValueBrush (Get-JValueBrush $Token) -Token $Token
        $search = "$Key $text"
    }
    [void]$Owner.Items.Add($tvi)
    $script:treeNodes += @{ Item = $tvi; Text = $search.ToLowerInvariant() }
}

# Build the whole tree from a parsed Newtonsoft JToken.
function Set-ResultTree {
    param($Token)   # [Newtonsoft.Json.Linq.JToken]
    $ui.ResultMessage.Visibility = 'Collapsed'
    $ui.ResultTree.Visibility = 'Visible'
    $ui.ResultTree.Items.Clear()
    $script:treeNodes = @()
    Reset-Find
    if ($Token -is [Newtonsoft.Json.Linq.JArray]) {
        $i = 0; foreach ($it in $Token) { Add-JsonTree $ui.ResultTree "$i" $it; $i++ }
    } elseif ($Token -is [Newtonsoft.Json.Linq.JObject]) {
        foreach ($p in @($Token.Properties())) { Add-JsonTree $ui.ResultTree $p.Name $p.Value }
    } else {
        Add-JsonTree $ui.ResultTree $null $Token
    }
    Set-TreeExpanded $true   # everything expanded by default
}

# Plain-text fallback (running / preview / errors / empty).
function Set-ResultMessage {
    param([string]$Text)
    $ui.ResultTree.Visibility = 'Collapsed'
    $ui.ResultTree.Items.Clear()
    $script:treeNodes = @()
    Reset-Find
    $ui.ResultMessage.Text = $Text
    $ui.ResultMessage.Visibility = 'Visible'
}

function Set-TreeExpanded {
    param([bool]$Expanded)
    foreach ($node in $script:treeNodes) { $node.Item.IsExpanded = $Expanded }
}

function Show-Result {
    if ($null -eq $script:accum -or ($script:isCollection -and $script:accum.Count -eq 0)) {
        $script:resultText = '[]'
        Set-ResultMessage 'No results.'
        $ui.ResultStatus.Text = if ($script:isCollection) { '0 items' } else { 'Result' }
        $ui.LoadMoreButton.Visibility = 'Collapsed'
        return
    }
    # Parse once with Newtonsoft: pretty JSON for Copy, and the JToken drives the tree.
    # -InputObject keeps a 1-item list a list (piping would unroll it), and
    # DateParseHandling=None keeps Graph's date strings exactly as sent.
    $json = ConvertTo-Json -InputObject $script:accum -Depth 20
    try {
        $reader = New-Object Newtonsoft.Json.JsonTextReader (New-Object System.IO.StringReader $json)
        $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $token = [Newtonsoft.Json.Linq.JToken]::ReadFrom($reader)
        $script:resultText = $token.ToString([Newtonsoft.Json.Formatting]::Indented)
        Set-ResultTree $token
    } catch {
        $script:resultText = $json
        Set-ResultMessage $script:resultText
    }

    if ($script:isCollection) {
        $more = if ($script:nextLink) { '  (more available)' } else { '' }
        $ui.ResultStatus.Text = "$($script:accum.Count) item(s)$more"
    } else { $ui.ResultStatus.Text = 'Result' }
    # Load more only appears when Graph paged the result (an @odata.nextLink).
    $ui.LoadMoreButton.Visibility = if ($script:nextLink) { 'Visible' } else { 'Collapsed' }
}

function Get-NextLink {
    param($Data)
    if ($Data.PSObject.Properties.Name -contains '@odata.nextLink') { $Data.'@odata.nextLink' } else { $null }
}

# --------------------------------------------------- loading spinner (results area)
function Start-Spinner {
    param([string] $Text = 'Running query...')
    $ui.SpinnerText.Text = $Text
    $ui.ResultSpinner.Visibility = 'Visible'
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = 0; $a.To = 360
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(850))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.SpinnerRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
}
function Stop-Spinner {
    $ui.SpinnerRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $ui.ResultSpinner.Visibility = 'Collapsed'
}

# --------------------------------------------------- async Graph request
# Runs Invoke-GraphRequest on a background runspace so the UI thread stays free
# (the spinner animates, the window stays responsive). A DispatcherTimer polls
# for completion and hands the result to the matching Complete-* handler.
function Start-GraphAsync {
    # $Request is @{ Type='single'; Uri=... } or
    #            @{ Type='chain'; Steps=...; Value=...; Select=...; Base=... }
    param([Parameter(Mandatory)][hashtable] $Request, [Parameter(Mandatory)][string] $Kind)
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($GraphModulePath, $Token, $Request, $Headers)
        Import-Module $GraphModulePath -Force
        if ($Request.Type -eq 'chain') {
            Invoke-GraphChain -AccessToken $Token -Steps $Request.Steps -Value $Request.Value `
                              -SelectCsv $Request.Select -Base $Request.Base -Headers $Headers
        } else {
            Invoke-GraphRequest -AccessToken $Token -Uri $Request.Uri -Headers $Headers
        }
    }).AddArgument($GraphModule).AddArgument($state.AccessToken).AddArgument($Request).AddArgument($script:queryHeaders)
    $script:queryRun = @{ PS = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs; Kind = $Kind }
    $ui.RunButton.IsEnabled = $false
    $ui.LoadMoreButton.IsEnabled = $false
    Start-Spinner -Text $(if ($Kind -eq 'more') { 'Loading more...' } else { 'Running query...' })
    $script:queryTimer.Start()
}

function Stop-QueryAsync {
    if (-not $script:queryRun) { return }
    try { $script:queryRun.PS.Dispose() } catch { }
    try { $script:queryRun.Runspace.Dispose() } catch { }
    $script:queryRun = $null
}

$script:queryTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:queryTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:queryTimer.Add_Tick({
    if (-not $script:queryRun -or -not $script:queryRun.Handle.IsCompleted) { return }
    $script:queryTimer.Stop()
    $run = $script:queryRun; $r = $null; $err = $null
    try {
        $out = $run.PS.EndInvoke($run.Handle)
        if ($run.PS.HadErrors -and $run.PS.Streams.Error.Count) { $err = $run.PS.Streams.Error[0].ToString() }
        else { $a = @($out); if ($a.Count) { $r = $a[-1] } }   # empty -> "No response from Graph."
    } catch {
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }   # unwrap EndInvoke
        $err = $ex.Message
    } finally { Stop-QueryAsync }

    Stop-Spinner
    $ui.RunButton.IsEnabled = $true
    $ui.LoadMoreButton.IsEnabled = $true   # re-enable after the request completes
    if ($run.Kind -eq 'more') { Complete-LoadMore -R $r -Err $err } else { Complete-Query -R $r -Err $err }
})

function Invoke-Query {
    if (-not $state.IsAuthenticated -or $script:queryRun) { return }

    $lk = Get-CurrentLookup
    $value = $ui.ValueBox.Text.Trim()
    $chain = if ($lk) { Get-Prop $lk 'Chain' } else { $null }

    if ($script:previewMode) {
        # Same input checks as a real run, then fake data shaped like the query.
        $tpl = if ($chain) { [string](Get-Prop @($chain)[-1] 'Url') } elseif ($lk) { [string](Get-Prop $lk 'Url') } else { '' }
        $needsValue = $chain -or ((-not $script:advancedMode) -and $tpl -match '\{value\}')
        if ($needsValue -and -not $value) { $ui.ResultStatus.Text = 'Enter a value'; return }
        Invoke-PreviewQuery -Template $tpl
        return
    }

    # Chained lookup: always runs the full chain (even in Advanced mode, where the
    # box is a read-only preview). $select/Return Properties apply to the last step.
    if ($chain) {
        if (-not $value) { $ui.ResultStatus.Text = 'Enter a value'; return }
        $ui.ResultStatus.Text = 'Running...'; Set-ResultMessage ''
        Start-GraphAsync -Request @{ Type = 'chain'; Steps = @($chain); Value = $value; Select = (Get-CheckedProps); Base = $Config.GraphV1 } -Kind 'query'
        return
    }

    if ($script:advancedMode) {
        # Non-chain: run the user's (possibly edited) URL verbatim; allow relative too.
        $uri = $ui.AdvancedUrlBox.Text.Trim()
        if (-not $uri) { $ui.ResultStatus.Text = 'Enter a URL'; return }
        if ($uri -notmatch '^https?://') { $uri = "$($Config.GraphV1)/$($uri.TrimStart('/'))" }
        $ui.ResultStatus.Text = 'Running...'; Set-ResultMessage ''
        Start-GraphAsync -Request @{ Type = 'single'; Uri = $uri } -Kind 'query'
        return
    }

    if (-not $lk) { return }
    $url = Get-Prop $lk 'Url'
    # A value is required unless the URL template has no {value} (e.g. "me").
    if (($url -match '\{value\}') -and -not $value) { $ui.ResultStatus.Text = 'Enter a value'; return }
    try {
        $uri = New-GraphQueryUri -Url $url -Value $value -SelectCsv (Get-CheckedProps) -Base $Config.GraphV1
    } catch { $ui.ResultStatus.Text = 'Error'; $script:resultText = $_.Exception.Message; Set-ResultMessage $script:resultText; return }
    $ui.ResultStatus.Text = 'Running...'; Set-ResultMessage ''
    Start-GraphAsync -Request @{ Type = 'single'; Uri = $uri } -Kind 'query'
}

# Preview mode: no Graph call. A URL template ending in me / {value} / manager
# (e.g. "users/{value}") is a single object; anything else is a paged list.
# Ticked Return Properties are applied like $select would.
function Invoke-PreviewQuery {
    param([string] $Template)
    $path = ($Template -split '\?')[0].TrimEnd('/')
    $sel = @((Get-CheckedProps) -split ',' | Where-Object { $_ })
    $script:previewSelect = $sel
    $ui.ResultStatus.Text = 'Running...'; Set-ResultMessage ''
    if ($path -match '(^|/)(me|\{value\}|manager)$') {
        $obj = @(Get-PreviewUsers 1 1)[0]
        if ($path -eq 'me') {   # match the fake signed-in identity
            $obj.displayName = $state.User.displayName; $obj.userPrincipalName = $state.User.userPrincipalName; $obj.mail = $state.User.mail
        }
        $script:isCollection = $false; $script:nextLink = $null
        $script:accum = if ($sel.Count) { $obj | Select-Object $sel } else { $obj }
    } else {
        $script:isCollection = $true
        $script:previewPage  = 1
        $script:accum        = [System.Collections.ArrayList]@(Get-PreviewUsers 1 50 | Select-PreviewProps)
        $script:nextLink     = 'preview://next'
    }
    Show-Result
}
filter Select-PreviewProps { if ($script:previewSelect.Count) { $_ | Select-Object $script:previewSelect } else { $_ } }

# Fake @microsoft.graph user objects for preview mode.
function Get-PreviewUsers {
    param([int] $Start, [int] $Count)
    $depts  = 'Information Technology', 'Human Resources', 'Finance', 'Sales', 'Operations'
    $titles = 'Analyst', 'Manager', 'Specialist', 'Coordinator', 'Director'
    $offices = 'HQ - Floor 3', 'Remote', 'Branch - Austin', 'Branch - Dallas'
    for ($n = $Start; $n -lt ($Start + $Count); $n++) {
        [PSCustomObject]@{
            id                = '00000000-0000-4000-8000-{0:D12}' -f $n
            displayName       = "User $n Example"
            userPrincipalName = "user$n@contoso.com"
            mail              = "user$n@contoso.com"
            jobTitle          = $titles[$n % $titles.Count]
            department        = $depts[$n % $depts.Count]
            officeLocation    = $offices[$n % $offices.Count]
            accountEnabled    = ($n % 7 -ne 0)
        }
    }
}

function Complete-Query {
    param($R, [string] $Err)
    if ($Err)      { $ui.ResultStatus.Text = 'Error'; $script:resultText = $Err; Set-ResultMessage $Err; return }
    if (-not $R)   { $ui.ResultStatus.Text = 'Error'; $script:resultText = 'No response from Graph.'; Set-ResultMessage $script:resultText; return }
    if ($R.Unauthorized) { Invoke-SignOut -Reason 'Graph rejected the token (401) - please authenticate again.'; return }
    if (-not $R.Ok) { $ui.ResultStatus.Text = "Error $($R.StatusCode)"; $script:resultText = "$($R.Error)"; Set-ResultMessage $script:resultText; return }

    if ($R.Data.PSObject.Properties.Name -contains 'value') {
        $script:isCollection = $true
        $script:accum = [System.Collections.ArrayList]@($R.Data.value)
        $script:nextLink = Get-NextLink $R.Data
    } else {
        $script:isCollection = $false; $script:accum = $R.Data; $script:nextLink = $null
    }
    Show-Result
}

function Invoke-LoadMore {
    if (-not $script:nextLink -or $script:queryRun) { return }
    if ($script:previewMode) {
        $script:previewPage++
        [void]$script:accum.AddRange(@(Get-PreviewUsers ($script:accum.Count + 1) 50 | Select-PreviewProps))
        $script:nextLink = if ($script:previewPage -lt 4) { 'preview://next' } else { $null }
        Show-Result
        return
    }
    $ui.ResultStatus.Text = 'Loading more...'
    Start-GraphAsync -Request @{ Type = 'single'; Uri = $script:nextLink } -Kind 'more'
}

function Complete-LoadMore {
    param($R, [string] $Err)
    if ($Err -or -not $R) { $ui.ResultStatus.Text = 'Error loading more'; return }
    if ($R.Unauthorized) { Invoke-SignOut -Reason 'Graph rejected the token (401) - please authenticate again.'; return }
    if (-not $R.Ok) { $ui.ResultStatus.Text = "Error $($R.StatusCode)"; return }
    [void]$script:accum.AddRange(@($R.Data.value))
    $script:nextLink = Get-NextLink $R.Data
    Show-Result
}

# --------------------------------------------------- find bar (tree search)
function Reset-Find {
    $script:findMatches = @()
    $script:findPos = -1
    $script:findTerm = ''
    if ($ui.FindCountText) { $ui.FindCountText.Text = '' }
}

function Update-SearchWatermark {
    $ui.SearchWatermark.Visibility = if ([string]::IsNullOrEmpty($ui.SearchBox.Text)) { 'Visible' } else { 'Collapsed' }
}

# Dir: +1 next, -1 prev. Jumps to matching tree nodes, expanding ancestors.
function Find-Step {
    param([int] $Dir)
    $term = $ui.SearchBox.Text
    if (-not $term) { Reset-Find; return }
    if ($term -ne $script:findTerm) {
        $t = $term.ToLowerInvariant()
        $script:findMatches = @($script:treeNodes | Where-Object { $_.Text.Contains($t) } | ForEach-Object { $_.Item })
        $script:findTerm = $term; $script:findPos = -1
    }
    $n = $script:findMatches.Count
    if ($n -eq 0) { $ui.FindCountText.Text = 'No matches'; return }
    if ($script:findPos -lt 0) { $script:findPos = if ($Dir -ge 0) { 0 } else { $n - 1 } }
    else { $script:findPos = ((($script:findPos + $Dir) % $n) + $n) % $n }
    $it = $script:findMatches[$script:findPos]
    $p = $it.Parent
    while ($p -is [System.Windows.Controls.TreeViewItem]) { $p.IsExpanded = $true; $p = $p.Parent }
    $it.IsSelected = $true
    $it.BringIntoView()
    $ui.FindCountText.Text = "$($script:findPos + 1) / $n"
}
function Find-Next { Find-Step 1 }
function Find-Prev { Find-Step -1 }

# ---------------------------------------------------------------- wiring
$ui.AuthenticateButton.Add_Click({ Start-Authentication })
$ui.ReauthButton.Add_Click({ $ui.ProfilePopup.IsOpen = $false; Start-Authentication })
$ui.SignOutButton.Add_Click({ Invoke-SignOut -Reason '' })
# Popup with StaysOpen=False dismisses itself when the pill is clicked; without
# this guard the button's own click would immediately reopen it. If the popup
# just closed (< 250ms ago), treat the click as "close" and don't reopen.
$ui.ProfilePopup.Add_Closed({ $script:popupClosedAt = Get-Date })
$ui.ProfileButton.Add_Click({
    if (((Get-Date) - $script:popupClosedAt).TotalMilliseconds -gt 250) { $ui.ProfilePopup.IsOpen = $true }
})
$script:copyTokenResetTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:copyTokenResetTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:copyTokenResetTimer.Add_Tick({ $script:copyTokenResetTimer.Stop(); $ui.CopyTokenButton.Content = 'Copy token' })
$script:copyResultResetTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:copyResultResetTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:copyResultResetTimer.Add_Tick({ $script:copyResultResetTimer.Stop(); $ui.CopyResultButton.Content = 'Copy' })
$script:copyFlashBtn = $null
$script:copyFlashTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:copyFlashTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$script:copyFlashTimer.Add_Tick({ $script:copyFlashTimer.Stop(); if ($script:copyFlashBtn) { $script:copyFlashBtn.Content = [char]0xE8C8; $script:copyFlashBtn = $null } })
$ui.CopyTenantIdButton.Add_Click({ Copy-IdWithFlash $ui.CopyTenantIdButton $ui.PopupTenantIdText.Text })
$ui.CopyObjectIdButton.Add_Click({ Copy-IdWithFlash $ui.CopyObjectIdButton $ui.PopupObjectIdText.Text })
$ui.CopyTokenButton.Add_Click({
    if ($state.AccessToken) {
        $ui.CopyTokenButton.Content = if (Set-Clipboard-Safe $state.AccessToken) { 'Copied' } else { 'Copy failed' }
    } else {
        $ui.CopyTokenButton.Content = 'No token'
    }
    $script:copyTokenResetTimer.Stop(); $script:copyTokenResetTimer.Start()
})
$ui.CategoryCombo.Add_SelectionChanged({ Set-Category })
$ui.ActionCombo.Add_SelectionChanged({ Set-Action })
$ui.LookupCombo.Add_SelectionChanged({ Update-ValueStep })
$ui.ValueBox.Add_TextChanged({ Update-ValueWatermark; Update-AdvancedUrl })
$advHandler = {
    $script:advancedMode = [bool]$ui.AdvancedToggle.IsChecked
    $ui.StepAdvanced.Visibility = if ($script:advancedMode) { 'Visible' } else { 'Collapsed' }
    Update-AdvancedUrl
}
$ui.AdvancedToggle.Add_Checked($advHandler)
$ui.AdvancedToggle.Add_Unchecked($advHandler)
$ui.SettingsButton.Add_Click({ Show-ConfigEditor -Owner $window -OnSaved { Reload-Catalog } })
$ui.ProfileSettingsButton.Add_Click({ $ui.ProfilePopup.IsOpen = $false; Show-SettingsEditor -Owner $window -OnSaved { Reload-Settings } })
$ui.PreviewButton.Add_Click({ Enter-Preview })
$ui.PropsButton.Add_Click({ $ui.PropsPopup.IsOpen = -not $ui.PropsPopup.IsOpen })
$ui.PropsSearch.Add_TextChanged({ Update-PropsFilter })
$ui.PropsSelectAll.Add_Click({ Set-AllProps $true })
$ui.PropsClear.Add_Click({ Set-AllProps $false })
$ui.RunButton.Add_Click({ Invoke-Query })
$ui.ValueBox.Add_KeyDown({ if ($_.Key -eq 'Return') { Invoke-Query } })
$ui.LoadMoreButton.Add_Click({ Invoke-LoadMore })
$ui.FindNextButton.Add_Click({ Find-Next })
$ui.FindPrevButton.Add_Click({ Find-Prev })
# Keep the results row at its MinHeight: cap the builder card to what's left
# (it scrolls internally when Advanced mode makes it tall). Measured from the
# window's root grid: SignedInRoot itself never shrinks below its content.
$script:layoutRoot = $ui.SignedInRoot.Parent
$fitBuilder = {
    $r = $ui.SignedInRoot
    $total = $script:layoutRoot.ActualHeight - $r.Margin.Top - $r.Margin.Bottom -
             $ui.TopBar.ActualHeight - $ui.TopBar.Margin.Bottom - $ui.BuilderCard.Margin.Bottom
    # Results get 380 (~300px of tree) when there's room; on short windows they
    # give up to 80px so the builder keeps ~280px.
    $rowMin = [Math]::Max(300, [Math]::Min(380, $total - 280))
    $r.RowDefinitions[2].MinHeight = $rowMin
    $ui.BuilderCard.MaxHeight = [Math]::Max(160, $total - $rowMin)
}
$script:layoutRoot.Add_SizeChanged($fitBuilder)
$ui.TopBar.Add_SizeChanged($fitBuilder)   # TopBar is 0 tall until signed in

# Right-click selects the row it's on (so it's clear what the menu will copy);
# Ctrl+C copies the selected row's value / object.
$ui.ResultTree.Add_PreviewMouseRightButtonDown({
    param($s, $e)
    $p = $e.OriginalSource
    while ($p -is [System.Windows.Media.Visual] -and -not ($p -is [System.Windows.Controls.TreeViewItem])) { $p = [System.Windows.Media.VisualTreeHelper]::GetParent($p) }
    if ($p -is [System.Windows.Controls.TreeViewItem]) { $p.IsSelected = $true }
})
$ui.ResultTree.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -ne 'C' -or [System.Windows.Input.Keyboard]::Modifiers -ne 'Control') { return }
    $it = $ui.ResultTree.SelectedItem
    if ($it) { [void](Set-Clipboard-Safe (Get-TokenCopyText $it.Tag)); $e.Handled = $true }
})
$ui.ExpandAllButton.Add_Click({ Set-TreeExpanded $true })
$ui.CollapseAllButton.Add_Click({ Set-TreeExpanded $false })
$ui.SearchBox.Add_TextChanged({ Update-SearchWatermark; if (-not $ui.SearchBox.Text) { Reset-Find } })
$ui.SearchBox.Add_KeyDown({
    if ($_.Key -eq 'Return') {
        if ($_.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) { Find-Prev } else { Find-Next }
    }
})
$ui.CopyResultButton.Add_Click({
    if ($script:resultText) {
        $ui.CopyResultButton.Content = if (Set-Clipboard-Safe $script:resultText) { 'Copied' } else { 'Copy failed' }
        $script:copyResultResetTimer.Stop(); $script:copyResultResetTimer.Start()
    }
})
$window.Add_Closed({ $script:timer.Stop(); $script:captureTimer.Stop(); $script:queryTimer.Stop(); Stop-CaptureAsync; Stop-QueryAsync })

# Safety net: any exception escaping a UI event/timer shows a popup instead of
# crashing the app.
$window.Dispatcher.add_UnhandledException({
    param($sender, $e)
    try { [System.Windows.MessageBox]::Show($e.Exception.Message, 'Aducks - Error', 'OK', 'Error') | Out-Null } catch { }
    $e.Handled = $true
})

# ---------------------------------------------------------------- run
Set-StepLabels
foreach ($c in $Categories) { [void]$ui.CategoryCombo.Items.Add($c.Category) }
$ui.CategoryCombo.SelectedIndex = 0   # triggers Set-Category -> Set-Action
Initialize-WindowChrome $window
Show-SignedOut
if ($Preview) { Enter-Preview }
if ($NoActivate) { $window.ShowActivated = $false }
[void]$window.ShowDialog()
