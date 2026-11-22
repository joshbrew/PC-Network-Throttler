[CmdletBinding()]
param(
    [ValidateRange(1, 10000)][int] $UploadMbps = 20,
    [switch] $WithPacketSupport,
    [ValidateSet('Install', 'Reinstall', 'Uninstall')][string] $Mode = 'Install',
    [ValidateSet('Preserve', 'Create', 'Remove')][string] $DesktopShortcut = 'Preserve'
)

$ErrorActionPreference = 'Stop'
$productName = 'Network Throttler'
$policyName = 'PC Upload Limit'
$taskName = 'PC Upload Limit'
$appVersion = '1.0'
# Build versions also order the previews that used a higher display version.
$packageBuildVersion = [version]'2.3.2'
$packetWorkerVersion = [version]'2.2.0'
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$folder = Join-Path $programFiles $productName
$legacyFolder = Join-Path $programFiles $policyName
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PCUploadLimit'
if (Test-Path -LiteralPath $uninstallKey) {
    $registered = Get-ItemProperty -LiteralPath $uninstallKey
    if ($registered.InstallLocation -eq $legacyFolder) { $folder = $legacyFolder }
}
$control = Join-Path $folder 'UploadLimit.ps1'
$settingsPath = Join-Path $folder 'Settings.json'
$desktop = [Environment]::GetFolderPath('DesktopDirectory', 'DoNotVerify')
$link = if ($desktop) { Join-Path $desktop 'Network Throttler.lnk' }
$shellPath = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$launchArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $control + '" -Action '
$uninstallCommand = '"' + $shellPath + '" ' + $launchArguments + 'Uninstall'
$linkDescription = 'Manage PC and per-app bandwidth limits, or uninstall.'
$iconLocation = (Join-Path ([Environment]::SystemDirectory) 'netshell.dll') + ',0'

function Get-LimiterShortcuts {
    if (!$desktop -or !(Test-Path -LiteralPath $desktop -PathType Container)) { return }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($file in Get-ChildItem -LiteralPath $desktop -File -Filter '*.lnk') {
        $shortcut = $shell.CreateShortcut($file.FullName)
        if ($shortcut.TargetPath -eq $shellPath -and $shortcut.Arguments -eq ($launchArguments + 'Desktop')) {
            [pscustomobject]@{ Path = $file.FullName; Description = $shortcut.Description }
        }
    }
}

$recognized = $false
$needsUpgrade = $false
$needsShortcutSync = $false
$needsShortcutPreference = $false
$previousShortcut = $true
$wantShortcut = $DesktopShortcut -ne 'Remove'
$needsPacketSupport = $WithPacketSupport -and !(Get-Service -Name PCUploadLimitShaper -ErrorAction SilentlyContinue)
if (Test-Path -LiteralPath $uninstallKey) {
    $installed = Get-ItemProperty -LiteralPath $uninstallKey
    $recognized = $installed.InstallLocation -eq $folder -and $installed.UninstallString -eq $uninstallCommand -and
        (Test-Path -LiteralPath $control -PathType Leaf) -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)
    if ($recognized) {
        $installedBuildVersion = if ($installed.PackageBuildVersion) {
            [version]$installed.PackageBuildVersion
        } else {
            [version]$installed.DisplayVersion
        }
        $needsUpgrade = $installedBuildVersion -lt $packageBuildVersion -or
            ($installedBuildVersion -eq $packageBuildVersion -and $installed.DisplayVersion -ne $appVersion)
        $preference = $installed.PSObject.Properties['DesktopShortcutEnabled']
        if ($preference) { $previousShortcut = [bool]$preference.Value }
        if ($DesktopShortcut -eq 'Preserve') { $wantShortcut = $previousShortcut }
        $needsShortcutPreference = !$preference -or $previousShortcut -ne $wantShortcut
        $shortcuts = @(Get-LimiterShortcuts)
        $needsShortcutSync = if ($wantShortcut) {
            $shortcuts.Count -ne 1 -or $shortcuts[0].Path -ne $link -or $shortcuts[0].Description -ne $linkDescription
        } else { $shortcuts.Count -gt 0 }
    }
    if ($Mode -eq 'Install' -and $recognized -and !$needsUpgrade -and !$needsPacketSupport -and
        !$needsShortcutSync -and !$needsShortcutPreference) {
        Write-Output 'Network Throttler is already installed. Open it with Run.cmd.'
        return
    }
}
if ($Mode -ne 'Install' -and !$recognized) { throw 'A supported Network Throttler installation could not be found.' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "' + $PSCommandPath + '" -UploadMbps ' + $UploadMbps +
        ' -Mode ' + $Mode + ' -DesktopShortcut ' + $DesktopShortcut
    if ($WithPacketSupport) { $arguments += ' -WithPacketSupport' }
    $elevated = Start-Process -FilePath $shellPath -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    if ($elevated.ExitCode -ne 0) { throw 'Setup failed. Run scripts\Install.ps1 in an administrator PowerShell window to see the error.' }
    return
}

function Close-LimiterWindows {
    $openWindows = Get-Process -Name powershell -ErrorAction SilentlyContinue |
        Where-Object MainWindowTitle -In $productName, $policyName
    foreach ($window in $openWindows) {
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $window.Id)
        if (!$process.CommandLine -or $process.CommandLine.IndexOf('"' + $control + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $process.CommandLine -notmatch '\s-Action\s+Desktop\s*$') { continue }
        $window.CloseMainWindow() | Out-Null
        if (!$window.WaitForExit(8000)) { throw 'Close the Network Throttler window and try setup again.' }
    }
}

function Restore-PreviousLimits($saved, [bool] $hadPacketSupport) {
    $priorShortcut = if ($previousShortcut) { 'Create' } else { 'Remove' }
    & $PSCommandPath -UploadMbps ([int]$saved.UploadMbps) -WithPacketSupport:$hadPacketSupport -DesktopShortcut $priorShortcut | Out-Null
    $restored = Get-ItemProperty -LiteralPath $uninstallKey
    $restoredControl = Join-Path $restored.InstallLocation 'UploadLimit.ps1'
    if ($hadPacketSupport) {
        $workerStatus = Join-Path $restored.InstallLocation 'PacketLimiter.status'
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if ((Test-Path -LiteralPath $workerStatus) -and (Get-Content -LiteralPath $workerStatus -Raw) -in 'Ready', 'Active') { break }
            Start-Sleep -Milliseconds 250
        }
    }
    $downloadRate = if ($saved.DownloadMbps) { [int]$saved.DownloadMbps } else { 50 }
    & $restoredControl -Action SetDevice -UploadMbps ([int]$saved.UploadMbps) -DownloadMbps $downloadRate `
        -LimitUpload:([bool]$saved.Enabled) -LimitDownload:([bool]$saved.DownloadEnabled)
    foreach ($rule in $saved.Apps | Where-Object Path) {
        & $restoredControl -Action SetApp -AppPath $rule.Path -UploadMbps $rule.UploadMbps -DownloadMbps $rule.DownloadMbps `
            -LimitUpload:([bool]$rule.UploadEnabled) -LimitDownload:([bool]$rule.DownloadEnabled)
    }
}

if ($Mode -eq 'Uninstall') {
    Close-LimiterWindows
    & $control -Action Uninstall -Quiet
    return
}
if ($Mode -eq 'Reinstall') {
    Close-LimiterWindows
    $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $hadPacketSupport = [bool](Get-Service -Name PCUploadLimitShaper -ErrorAction SilentlyContinue)
    $backup = Join-Path ([IO.Path]::GetTempPath()) ('Network-Throttler-settings-' + [Guid]::NewGuid().ToString('N') + '.json')
    Copy-Item -LiteralPath $settingsPath -Destination $backup
    $newShortcut = if ($wantShortcut) { 'Create' } else { 'Remove' }
    try {
        & $control -Action Uninstall -Quiet
        & $PSCommandPath -UploadMbps $UploadMbps -WithPacketSupport:$WithPacketSupport -DesktopShortcut $newShortcut
    } catch {
        $reinstallError = $_
        try {
            Restore-PreviousLimits $saved $hadPacketSupport
        } catch {
            throw "Reinstall failed: $($reinstallError.Exception.Message) Previous settings are backed up at $backup. Recovery failed: $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $backup
        throw "Reinstall failed: $($reinstallError.Exception.Message) The previous settings were restored."
    }
    Remove-Item -LiteralPath $backup
    return
}

function Copy-LimiterFiles {
    $sourceDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    $catalog = Join-Path $folder 'AppCatalog.dll'
    $catalogStage = $catalog + '.new'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    try {
        & $compiler /nologo /target:library /optimize+ ('/out:' + $catalogStage) (Join-Path $sourceDirectory 'AppCatalog.cs') `
            (Join-Path $sourceDirectory 'NetworkMonitor.cs')
        if ($LASTEXITCODE) { throw 'Compiling the running-app catalog failed.' }
        if (Test-Path -LiteralPath $catalog) { [IO.File]::Replace($catalogStage, $catalog, [NullString]::Value) }
        else { Move-Item -LiteralPath $catalogStage -Destination $catalog }
    } finally {
        if (Test-Path -LiteralPath $catalogStage) { Remove-Item -LiteralPath $catalogStage }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LimiterWindow.ps1') -Destination $folder
    Copy-Item -LiteralPath (Join-Path $sourceDirectory 'LimiterWindow.xaml') -Destination $folder
    $staged = $control + '.new'
    try {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UploadLimit.ps1') -Destination $staged
        if (Test-Path -LiteralPath $control) { [IO.File]::Replace($staged, $control, [NullString]::Value) }
        else { Move-Item -LiteralPath $staged -Destination $control }
    } finally {
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged }
    }
}

function Sync-LimiterShortcut {
    if (!$wantShortcut) {
        foreach ($candidate in Get-LimiterShortcuts) { Remove-Item -LiteralPath $candidate.Path }
        return
    }
    if (!$desktop -or !(Test-Path -LiteralPath $desktop -PathType Container)) { throw 'The desktop folder is unavailable.' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    if ((Test-Path -LiteralPath $link) -and
        ($shortcut.TargetPath -ne $shellPath -or $shortcut.Arguments -ne ($launchArguments + 'Desktop'))) {
        throw 'A different desktop shortcut uses the limiter name.'
    }
    $shortcut.TargetPath = $shellPath
    $shortcut.Arguments = $launchArguments + 'Desktop'
    $shortcut.WorkingDirectory = [Environment]::SystemDirectory
    $shortcut.Description = $linkDescription
    $shortcut.IconLocation = $iconLocation
    $shortcut.Save()

    $saved = $shell.CreateShortcut($link)
    if ($saved.TargetPath -ne $shellPath -or $saved.Arguments -ne ($launchArguments + 'Desktop')) {
        throw 'The desktop shortcut did not save correctly.'
    }
    foreach ($candidate in Get-LimiterShortcuts) {
        if ($candidate.Path -ne $link) { Remove-Item -LiteralPath $candidate.Path }
    }
}

if ($needsPacketSupport -or $needsUpgrade) { . (Join-Path $PSScriptRoot 'Install-PacketSupport.ps1') }
if ($recognized) {
    if ($needsUpgrade) {
        Close-LimiterWindows
        if ($installedBuildVersion -lt $packetWorkerVersion -and
            (Get-Service -Name PCUploadLimitShaper -ErrorAction SilentlyContinue)) { Update-PacketWorker $folder }
        Copy-LimiterFiles
        if ($needsShortcutSync) { Sync-LimiterShortcut }
        Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayName -Value $productName
        Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $appVersion
        New-ItemProperty -LiteralPath $uninstallKey -Name PackageBuildVersion -Value $packageBuildVersion.ToString() -PropertyType String -Force | Out-Null
    } elseif ($needsShortcutSync) {
        Sync-LimiterShortcut
    }
    if ($needsShortcutPreference) {
        New-ItemProperty -LiteralPath $uninstallKey -Name DesktopShortcutEnabled -Value ([int]$wantShortcut) -PropertyType DWord -Force | Out-Null
    }
    if ($needsPacketSupport) { Install-PacketSupport $folder }
    & $control -Action Status
    return
}

if (Test-Path -LiteralPath $folder) { throw "An install folder already exists at $folder." }
if ($wantShortcut -and $link -and (Test-Path -LiteralPath $link)) { throw 'The desktop shortcut already exists.' }
if (Test-Path -LiteralPath $uninstallKey) { throw 'A Windows uninstall entry already exists.' }
if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'A scheduled task with this name already exists.' }
if ($wantShortcut -and (!$desktop -or !(Test-Path -LiteralPath $desktop -PathType Container))) { throw 'The desktop folder is unavailable.' }
$policies = @(Get-NetQosPolicy) + @(Get-NetQosPolicy -PolicyStore ActiveStore)
if ($policies.Name -contains $policyName) { throw 'A Windows QoS rule with this name already exists.' }

$createdFolder = $false
try {
    New-Item -ItemType Directory -Path $folder | Out-Null
    $createdFolder = $true
    Copy-LimiterFiles
    @{ UploadMbps = $UploadMbps; Enabled = $false; DownloadMbps = 50; DownloadEnabled = $false; Apps = @(); Shortcut = $link } |
        ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8

    $taskAction = New-ScheduledTaskAction -Execute $shellPath -Argument ($launchArguments + 'StartAtBoot') -WorkingDirectory ([Environment]::SystemDirectory)
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $taskAction -Trigger $taskTrigger `
        -Principal $taskPrincipal -Settings $taskSettings -Description 'Restore the saved PC upload limit after Windows starts.' | Out-Null

    $status = & $control -Action Enable
    if (!$status.Enabled -or !$status.StartsWithWindows) { throw 'The upload cap did not activate.' }

    if ($wantShortcut) { Sync-LimiterShortcut }

    New-Item -Path $uninstallKey | Out-Null
    $registration = @{
        DisplayName = $productName
        DisplayVersion = $appVersion
        PackageBuildVersion = $packageBuildVersion.ToString()
        DisplayIcon = $iconLocation
        InstallLocation = $folder
        UninstallString = $uninstallCommand
        QuietUninstallString = $uninstallCommand + ' -Quiet'
    }
    foreach ($entry in $registration.GetEnumerator()) {
        New-ItemProperty -LiteralPath $uninstallKey -Name $entry.Key -Value $entry.Value -PropertyType String | Out-Null
    }
    New-ItemProperty -LiteralPath $uninstallKey -Name NoModify -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $uninstallKey -Name DesktopShortcutEnabled -Value ([int]$wantShortcut) -PropertyType DWord | Out-Null

    if ($needsPacketSupport) { Install-PacketSupport $folder }
    [pscustomobject]@{ Shortcut = $(if ($wantShortcut) { $link }); Enabled = $status.Enabled; BitsPerSecond = $status.BitsPerSecond }
} catch {
    if ($createdFolder) {
        try {
            if ((Test-Path -LiteralPath $control) -and (Test-Path -LiteralPath $settingsPath)) {
                & $control -Action Uninstall -Quiet
            } else {
                foreach ($path in $control, $settingsPath, (Join-Path $folder 'LimiterWindow.ps1'), (Join-Path $folder 'LimiterWindow.xaml'), (Join-Path $folder 'AppCatalog.dll')) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
                }
                Remove-Item -LiteralPath $folder
            }
        } catch { Write-Warning "Setup cleanup failed. $($_.Exception.Message)" }
    }
    throw
}
