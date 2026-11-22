Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$catalogAssembly = Join-Path $PSScriptRoot 'AppCatalog.dll'
[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($catalogAssembly)) | Out-Null
$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'LimiterWindow.xaml')))
$controlPath = Join-Path $PSScriptRoot 'UploadLimit.ps1'
$settingsFile = Join-Path $PSScriptRoot 'Settings.json'
$ui = @{}
foreach ($name in 'EngineStatus','MonitorStatus','DeviceEditor','GlobalUploadCheck','GlobalUploadRate','GlobalDownloadCheck','GlobalDownloadRate',
    'SaveGlobal','AppSearch','SearchHint','AppList','SelectedApp','AppEditor','AppUploadCheck','AppUploadRate','AppDownloadCheck',
    'AppDownloadRate','SaveApp','ClearApp','Uninstall','SourceLink','Feedback') { $ui[$name] = $window.FindName($name) }

$catalog = [PcLimiter.AppCatalog]::new()
$view = @{
    Loading = $false; Reloading = $false; Snapshot = $catalog.Snapshot; Settings = Get-UploadSettings
    Engine = Get-PacketShaperStatus; NextStatus = [DateTime]::UtcNow.AddSeconds(4)
    Sort = 'Running'; Descending = $true; Pending = $null; CloseAfterSave = $false
    SettingsModified = [IO.File]::GetLastWriteTimeUtc($settingsFile)
}
$columns = @($ui.AppList.View.Columns | ForEach-Object {
    [pscustomobject]@{ Header = $_.Header; Label = [string]$_.Header.Content; Field = [string]$_.Header.Tag }
})

function Get-Rate([string] $Text) {
    $rate = 0
    if (![int]::TryParse($Text.Trim(), [ref]$rate) -or $rate -lt 1 -or $rate -gt 10000) {
        throw 'Enter a whole-number speed from 1 to 10,000 Mbps.'
    }
    $rate
}

function Show-EditorAvailability {
    $available = $view.Engine -in 'Ready', 'Active'
    $idle = !$view.Pending
    $selection = $ui.AppList.SelectedItem
    $ui.DeviceEditor.IsEnabled = $idle
    $ui.GlobalDownloadCheck.IsEnabled = $available -or $ui.GlobalDownloadCheck.IsChecked
    $ui.AppEditor.IsEnabled = $idle -and $selection -and ($available -or [bool]$selection.Rule)
    $ui.Uninstall.IsEnabled = $idle
    $ui.EngineStatus.Text = switch ($view.Engine) {
        'Ready' { 'Packet shaping ready' }
        'Active' { 'Packet shaping active' }
        'Not installed' { 'Download and app limits require packet support' }
        default { "Packet shaping: $($view.Engine)" }
    }
}

function Show-GlobalSettings {
    $settings = $view.Settings
    $view.Loading = $true
    try {
        $ui.GlobalUploadCheck.IsChecked = $settings.Enabled
        $ui.GlobalUploadRate.Text = [string]$settings.UploadMbps
        $ui.GlobalDownloadCheck.IsChecked = $settings.DownloadEnabled
        $ui.GlobalDownloadRate.Text = [string]$settings.DownloadMbps
        Show-EditorAvailability
    } finally { $view.Loading = $false }
}

function Show-AppSettings {
    $row = $ui.AppList.SelectedItem
    $view.Loading = $true
    try {
        $ui.SelectedApp.Text = if ($row) { $row.Path } else { 'Select an app to edit its limits.' }
        $ui.SelectedApp.ToolTip = $row.Path
        $ui.AppUploadCheck.IsChecked = [bool]$row.Rule.UploadEnabled
        $ui.AppDownloadCheck.IsChecked = [bool]$row.Rule.DownloadEnabled
        $ui.AppUploadRate.Text = if ($row.Rule.UploadMbps) { [string]$row.Rule.UploadMbps } else { '5' }
        $ui.AppDownloadRate.Text = if ($row.Rule.DownloadMbps) { [string]$row.Rule.DownloadMbps } else { '20' }
        $ui.ClearApp.IsEnabled = [bool]$row.Rule
        Show-EditorAvailability
    } finally { $view.Loading = $false }
}

function Show-ColumnOrder {
    foreach ($column in $columns) {
        $marker = if ($column.Field -eq $view.Sort) {
            if ($view.Descending) { ' ' + [char]0x25BE } else { ' ' + [char]0x25B4 }
        } else { '' }
        $column.Header.Content = $column.Label + $marker
        [Windows.Automation.AutomationProperties]::SetName($column.Header, $column.Label)
        $column.Header.ToolTip = if ($column.Field -ne $view.Sort) { "Sort by $($column.Label)" }
            elseif ($view.Descending) { 'Sorted descending. Click for ascending.' }
            else { 'Sorted ascending. Click for descending.' }
    }
}

function Show-AppList {
    $search = $ui.AppSearch.Text.Trim()
    $ui.SearchHint.Visibility = if ($search) { 'Collapsed' } else { 'Visible' }
    $running = @{}
    $rules = @{}
    $paths = @{}
    $ui.MonitorStatus.Text = $view.Snapshot.MonitorStatus
    $ui.MonitorStatus.ToolTip = $view.Snapshot.MonitorStatus
    foreach ($app in $view.Snapshot.Apps) { $running[$app.Path] = $app; $paths[$app.Path] = $true }
    foreach ($rule in $view.Settings.Apps) { if ($rule.Path) { $rules[$rule.Path] = $rule; $paths[$rule.Path] = $true } }

    $rows = @(foreach ($path in $paths.Keys) {
        $app = $running[$path]
        $name = if ($app) { $app.Name } else { [IO.Path]::GetFileName($path) }
        if ($search -and $name.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $path.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $rule = $rules[$path]
        $upload = if ($rule.UploadEnabled) { [int]$rule.UploadMbps } else { 0 }
        $download = if ($rule.DownloadEnabled) { [int]$rule.DownloadMbps } else { 0 }
        $live = [PcLimiter.LiveRate]::new()
        $live.Set($view.Snapshot.RatesAvailable, [double]$app.UploadMbps, [double]$app.DownloadMbps)
        [pscustomobject]@{
            Name = $name
            Path = $path
            Running = [int]$app.Count
            Upload = if ($upload) { "$upload Mbps" } else { 'Off' }
            Download = if ($download) { "$download Mbps" } else { 'Off' }
            UploadSort = $upload
            DownloadSort = $download
            Live = $live
            Rule = $rule
        }
    })

    $sortBy = switch ($view.Sort) {
        'LiveUpload' { { $_.Live.Upload } }
        'LiveDownload' { { $_.Live.Download } }
        default { $view.Sort }
    }
    $order = @(@{ Expression = $sortBy; Descending = $view.Descending })
    foreach ($field in 'Name', 'Path') { if ($field -ne $view.Sort) { $order += $field } }
    $rows = @($rows | Sort-Object -Property $order)
    $selected = $ui.AppList.SelectedItem.Path
    $view.Reloading = $true
    try {
        $ui.AppList.ItemsSource = $rows
        if ($selected) {
            foreach ($item in $rows) {
                if ($item.Path -eq $selected) { $ui.AppList.SelectedItem = $item; break }
            }
        }
    } finally { $view.Reloading = $false }
    if ($selected -ne $ui.AppList.SelectedItem.Path) { Show-AppSettings }
}

function Update-AppRates {
    $ui.MonitorStatus.Text = $view.Snapshot.MonitorStatus
    $ui.MonitorStatus.ToolTip = $view.Snapshot.MonitorStatus
    $running = @{}
    foreach ($app in $view.Snapshot.Apps) { $running[$app.Path] = $app }
    foreach ($row in $ui.AppList.ItemsSource) {
        $app = $running[$row.Path]
        $row.Live.Set($view.Snapshot.RatesAvailable, [double]$app.UploadMbps, [double]$app.DownloadMbps)
    }
}

function Start-LimiterWrite([hashtable] $Parameters, [string] $Success) {
    if ($view.Pending) { return }
    $worker = [PowerShell]::Create()
    try {
        $worker.AddCommand($controlPath).AddParameters($Parameters) | Out-Null
        $view.Pending = @{ Worker = $worker; Operation = $worker.BeginInvoke(); Success = $Success; Parameters = $Parameters }
    } catch {
        $worker.Dispose()
        throw
    }
    $ui.Feedback.Text = 'Saving limits...'
    Show-EditorAvailability
}

function Finish-LimiterWrite {
    $pending = $view.Pending
    if (!$pending -or !$pending.Operation.IsCompleted) { return }
    $errorText = $null
    try {
        $pending.Worker.EndInvoke($pending.Operation) | Out-Null
        if ($pending.Worker.HadErrors) { $errorText = $pending.Worker.Streams.Error[0].ToString() }
    } catch { $errorText = $_.Exception.GetBaseException().Message }
    finally { $pending.Worker.Dispose(); $view.Pending = $null }

    $view.Settings = Get-UploadSettings
    $view.SettingsModified = [IO.File]::GetLastWriteTimeUtc($settingsFile)
    $direction = $pending.Parameters.Direction
    $isDevice = $pending.Parameters.Action -eq 'SetDevice'
    if ($isDevice) {
        $upDraft = $ui.GlobalUploadRate.Text
        $downDraft = $ui.GlobalDownloadRate.Text
        Show-GlobalSettings
        if ($direction -eq 'Download') { $ui.GlobalUploadRate.Text = $upDraft }
        if ($direction -eq 'Upload') { $ui.GlobalDownloadRate.Text = $downDraft }
    } else {
        $sameApp = $ui.AppList.SelectedItem.Path -eq $pending.Parameters.AppPath
        $upDraft = $ui.AppUploadRate.Text
        $downDraft = $ui.AppDownloadRate.Text
        Show-AppList
        if ($sameApp) {
            Show-AppSettings
            if ($direction -eq 'Download') { $ui.AppUploadRate.Text = $upDraft }
            if ($direction -eq 'Upload') { $ui.AppDownloadRate.Text = $downDraft }
        }
    }
    Show-EditorAvailability
    $ui.Feedback.Text = if ($errorText) { $errorText } else { $pending.Success }
    if ($view.CloseAfterSave) {
        $view.CloseAfterSave = $false
        if (!$errorText) { $window.Close() }
    }
}

function Save-DeviceEditor([string] $Direction = 'Both') {
    if ($view.Loading -or $view.Pending) { return }
    try {
        $upRate = if ($Direction -eq 'Both' -or ($Direction -eq 'Upload' -and $ui.GlobalUploadCheck.IsChecked)) {
            Get-Rate $ui.GlobalUploadRate.Text
        } else { $view.Settings.UploadMbps }
        $downRate = if ($Direction -eq 'Both' -or ($Direction -eq 'Download' -and $ui.GlobalDownloadCheck.IsChecked)) {
            Get-Rate $ui.GlobalDownloadRate.Text
        } else { $view.Settings.DownloadMbps }
        Start-LimiterWrite @{
            Action = 'SetDevice'; UploadMbps = $upRate; DownloadMbps = $downRate; Direction = $Direction
            LimitUpload = [bool]$ui.GlobalUploadCheck.IsChecked; LimitDownload = [bool]$ui.GlobalDownloadCheck.IsChecked
        } 'PC limits saved.'
    } catch {
        $ui.Feedback.Text = $_.Exception.Message
        Show-GlobalSettings
    }
}

function Save-AppEditor([string] $Direction = 'Both') {
    if ($view.Loading -or $view.Pending -or !$ui.AppList.SelectedItem) { return }
    try {
        $row = $ui.AppList.SelectedItem
        $upRate = if ($Direction -eq 'Both' -or ($Direction -eq 'Upload' -and $ui.AppUploadCheck.IsChecked)) {
            Get-Rate $ui.AppUploadRate.Text
        } elseif ($row.Rule.UploadMbps) { $row.Rule.UploadMbps } else { 5 }
        $downRate = if ($Direction -eq 'Both' -or ($Direction -eq 'Download' -and $ui.AppDownloadCheck.IsChecked)) {
            Get-Rate $ui.AppDownloadRate.Text
        } elseif ($row.Rule.DownloadMbps) { $row.Rule.DownloadMbps } else { 20 }
        Start-LimiterWrite @{
            Action = 'SetApp'; AppPath = $row.Path; UploadMbps = $upRate; DownloadMbps = $downRate; Direction = $Direction
            LimitUpload = [bool]$ui.AppUploadCheck.IsChecked; LimitDownload = [bool]$ui.AppDownloadCheck.IsChecked
        } 'App limits saved.'
    } catch {
        $ui.Feedback.Text = $_.Exception.Message
        Show-AppSettings
    }
}

foreach ($column in $columns) {
    $column.Header.Add_Click({
        param($header, $eventArgs)
        $field = [string]$header.Tag
        if ($view.Sort -eq $field) { $view.Descending = !$view.Descending }
        else { $view.Sort = $field; $view.Descending = $false }
        Show-ColumnOrder
        Show-AppList
    })
}

$ui.GlobalUploadCheck.Add_Checked({ Save-DeviceEditor 'Upload' })
$ui.GlobalUploadCheck.Add_Unchecked({ Save-DeviceEditor 'Upload' })
$ui.GlobalDownloadCheck.Add_Checked({ Save-DeviceEditor 'Download' })
$ui.GlobalDownloadCheck.Add_Unchecked({ Save-DeviceEditor 'Download' })
$ui.AppUploadCheck.Add_Checked({ Save-AppEditor 'Upload' })
$ui.AppUploadCheck.Add_Unchecked({ Save-AppEditor 'Upload' })
$ui.AppDownloadCheck.Add_Checked({ Save-AppEditor 'Download' })
$ui.AppDownloadCheck.Add_Unchecked({ Save-AppEditor 'Download' })
$ui.SaveGlobal.Add_Click({ Save-DeviceEditor })
$ui.SaveApp.Add_Click({ Save-AppEditor })
$ui.ClearApp.Add_Click({
    try { Start-LimiterWrite @{ Action = 'RemoveApp'; AppPath = $ui.AppList.SelectedItem.Path } 'App rule removed.' }
    catch { $ui.Feedback.Text = $_.Exception.Message }
})
$ui.AppSearch.Add_TextChanged({ Show-AppList })
$ui.AppList.Add_SelectionChanged({ if (!$view.Reloading) { Show-AppSettings } })
$ui.SourceLink.Add_RequestNavigate({
    param($sender, $navigation)
    $navigation.Handled = $true
    try {
        $shell = New-Object -ComObject Shell.Application
        $handle = 0
        $desktop = $shell.Windows().FindWindowSW(0, 0, 8, [ref]$handle, 1)
        if (!$desktop) { throw 'The Windows desktop browser launcher is unavailable.' }
        $desktop.Document.Application.ShellExecute($navigation.Uri.AbsoluteUri, '', '', 'open', 1)
    } catch { $ui.Feedback.Text = 'Could not open the GitHub source page.' }
})
$ui.Uninstall.Add_Click({
    try { if (Confirm-Uninstall) { $window.Close() } }
    catch { $ui.Feedback.Text = $_.Exception.Message }
})
$window.Add_Closing({
    param($sender, $closing)
    if ($view.Pending) {
        $closing.Cancel = $true
        $view.CloseAfterSave = $true
    }
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    try {
        Finish-LimiterWrite
        $latest = $catalog.Snapshot
        if (![object]::ReferenceEquals($latest, $view.Snapshot)) {
            $catalogChanged = $latest.CatalogVersion -ne $view.Snapshot.CatalogVersion
            $view.Snapshot = $latest
            if ($catalogChanged -or $view.Sort -in 'LiveUpload', 'LiveDownload') { Show-AppList }
            else { Update-AppRates }
        }
        if ([DateTime]::UtcNow -ge $view.NextStatus) {
            $view.NextStatus = [DateTime]::UtcNow.AddSeconds(4)
            $view.Engine = Get-PacketShaperStatus
            if (!$view.Pending -and [IO.File]::GetLastWriteTimeUtc($settingsFile) -ne $view.SettingsModified) {
                $view.Settings = Get-UploadSettings
                $view.SettingsModified = [IO.File]::GetLastWriteTimeUtc($settingsFile)
                Show-GlobalSettings
                Show-AppList
                Show-AppSettings
            }
            Show-EditorAvailability
        }
    } catch { $ui.Feedback.Text = $_.Exception.Message }
})
Show-GlobalSettings
Show-ColumnOrder
Show-AppList
Show-AppSettings
$timer.Start()
try { $window.ShowDialog() | Out-Null } finally { $timer.Stop(); $catalog.Dispose() }
