[CmdletBinding()]
param(
    [ValidateSet('Desktop', 'Enable', 'Disable', 'SetRate', 'SetDevice', 'SetDownload', 'SetApp', 'RemoveApp', 'StartAtBoot', 'Status', 'Uninstall')]
    [string] $Action = 'Desktop',
    [ValidateRange(1, 10000)][int] $UploadMbps,
    [ValidateRange(1, 10000)][int] $DownloadMbps,
    [string] $AppPath,
    [ValidateSet('Both', 'Upload', 'Download')][string] $Direction = 'Both',
    [switch] $LimitUpload,
    [switch] $LimitDownload,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$caption = 'Network Throttler'
$policyName = 'PC Upload Limit'
$taskName = 'PC Upload Limit'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PCUploadLimit'
$settingsPath = Join-Path $PSScriptRoot 'Settings.json'
$lockPath = Join-Path $PSScriptRoot 'Settings.lock'
$shellPath = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$launchArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $PSCommandPath + '" -Action '

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Action -in 'SetDevice', 'SetDownload', 'SetApp', 'RemoveApp') { throw 'Run this command from an administrator PowerShell session.' }
    $arguments = $launchArguments + $Action
    if ($PSBoundParameters.ContainsKey('UploadMbps')) { $arguments += ' -UploadMbps ' + $UploadMbps }
    if ($Quiet) { $arguments += ' -Quiet' }
    try {
        Start-Process -FilePath $shellPath -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -WorkingDirectory ([Environment]::SystemDirectory)
    } catch {
        if ($_.Exception.InnerException.NativeErrorCode -ne 1223 -and $_.Exception.NativeErrorCode -ne 1223) { throw }
    }
    return
}

function Get-UploadSettings {
    $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if (!$saved.PSObject.Properties['DownloadEnabled']) { $saved | Add-Member NoteProperty DownloadEnabled $false }
    if (!$saved.PSObject.Properties['DownloadMbps']) { $saved | Add-Member NoteProperty DownloadMbps 50 }
    if (!$saved.PSObject.Properties['Apps']) { $saved | Add-Member NoteProperty Apps @() }
    $saved
}

function Invoke-Locked([scriptblock] $Operation) {
    $lock = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    if (!$lock) { throw 'Network Throttler is busy. Try again in a few seconds.' }
    try { & $Operation } finally { $lock.Dispose() }
}

function Get-ActiveUploadPolicy {
    Get-NetQosPolicy -PolicyStore ActiveStore | Where-Object Name -EQ $policyName
}

function Get-UploadLimitStatus {
    $settings = Get-UploadSettings
    $active = Get-ActiveUploadPolicy
    [pscustomobject]@{
        Enabled = [bool]$active
        StartsWithWindows = [bool]$settings.Enabled
        UploadMbps = [int]$settings.UploadMbps
        BitsPerSecond = $active.ThrottleRateAction
        DownloadEnabled = [bool]$settings.DownloadEnabled
        DownloadMbps = [int]$settings.DownloadMbps
    }
}

function Set-ActiveUploadPolicy([uint64] $BitsPerSecond) {
    if ((Get-NetQosPolicy).Name -contains $policyName) { throw 'A separate local policy uses the same name.' }
    $active = Get-ActiveUploadPolicy
    if ($BitsPerSecond -eq 0) {
        if ($active) { Remove-NetQosPolicy -Name $policyName -PolicyStore ActiveStore -Confirm:$false }
    } elseif (!$active) {
        New-NetQosPolicy -Name $policyName -PolicyStore ActiveStore -Default -ThrottleRateActionBitsPerSecond $BitsPerSecond | Out-Null
    } elseif ($active.ThrottleRateAction -ne $BitsPerSecond) {
        Set-NetQosPolicy -Name $policyName -PolicyStore ActiveStore -ThrottleRateActionBitsPerSecond $BitsPerSecond | Out-Null
    }

    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $policy = Get-ActiveUploadPolicy
        if ($BitsPerSecond -eq 0 -and !$policy) { return }
        if ($BitsPerSecond -gt 0 -and $policy.ThrottleRateAction -eq $BitsPerSecond) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'Windows did not update the active upload limit.'
}

function Update-LimiterSettings([scriptblock] $Edit, [switch] $ReadOnly) {
    Invoke-Locked {
        $settings = Get-UploadSettings
        $previous = [uint64](Get-ActiveUploadPolicy).ThrottleRateAction
        if ($Edit) { & $Edit $settings }
        $desired = if ($settings.Enabled) { [uint64]$settings.UploadMbps * 1000000 } else { 0 }
        $temporary = $settingsPath + '.tmp'
        try {
            if ($previous -ne $desired) { Set-ActiveUploadPolicy $desired }
            if (!$ReadOnly) {
                $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
                [IO.File]::Replace($temporary, $settingsPath, [NullString]::Value)
            }
        }
        catch {
            if ([uint64](Get-ActiveUploadPolicy).ThrottleRateAction -ne $previous) { Set-ActiveUploadPolicy $previous }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        }
    }
}

function Set-UploadLimit([string] $Change, [int] $Rate) {
    if ($Change -eq 'StartAtBoot') { Update-LimiterSettings -ReadOnly; return }
    Update-LimiterSettings {
        param($edited)
        if ($Change -eq 'Enable') { $edited.Enabled = $true }
        if ($Change -eq 'Disable') { $edited.Enabled = $false }
        if ($Change -eq 'SetRate') { $edited.UploadMbps = $Rate }
    }
}

function Get-PacketShaperStatus {
    $service = Get-Service -Name PCUploadLimitShaper -ErrorAction SilentlyContinue
    if (!$service) { return 'Not installed' }
    if ($service.Status -ne 'Running') { return 'Stopped' }
    $statusPath = Join-Path $PSScriptRoot 'PacketLimiter.status'
    if (!(Test-Path -LiteralPath $statusPath)) { return 'Starting' }
    Get-Content -LiteralPath $statusPath -Raw
}

function Set-DeviceLimits([bool] $UpOn, [int] $UpRate, [bool] $DownOn, [int] $DownRate, [string] $Direction = 'Both') {
    if ($Direction -ne 'Upload' -and $DownOn -and (Get-PacketShaperStatus) -notin 'Ready', 'Active') { throw 'Packet shaping is unavailable.' }
    Update-LimiterSettings {
        param($edited)
        if ($Direction -ne 'Download') {
            $edited.Enabled = $UpOn
            $edited.UploadMbps = $UpRate
        }
        if ($Direction -ne 'Upload') {
            $edited.DownloadEnabled = $DownOn
            $edited.DownloadMbps = $DownRate
        }
    }
}

function Set-AppLimits([string] $Path, [bool] $UpOn, [int] $UpRate, [bool] $DownOn, [int] $DownRate,
    [switch] $Remove, [string] $Direction = 'Both') {
    if ((($Direction -ne 'Download' -and $UpOn) -or ($Direction -ne 'Upload' -and $DownOn)) -and
        (Get-PacketShaperStatus) -notin 'Ready', 'Active') { throw 'Packet shaping is unavailable.' }
    Update-LimiterSettings {
        param($edited)
        $previousRule = $edited.Apps | Where-Object Path -EQ $Path | Select-Object -First 1
        $edited.Apps = @($edited.Apps | Where-Object Path -NE $Path)
        if (!$Remove) {
            $rule = [pscustomobject]@{
                Path = $Path; UploadEnabled = $UpOn; UploadMbps = $UpRate; DownloadEnabled = $DownOn; DownloadMbps = $DownRate
            }
            if ($previousRule -and $Direction -eq 'Upload') {
                $rule.DownloadEnabled = $previousRule.DownloadEnabled
                $rule.DownloadMbps = $previousRule.DownloadMbps
            } elseif ($previousRule -and $Direction -eq 'Download') {
                $rule.UploadEnabled = $previousRule.UploadEnabled
                $rule.UploadMbps = $previousRule.UploadMbps
            }
            $edited.Apps += $rule
        }
    }
}

function Remove-UploadLimit {
    Set-UploadLimit 'Disable'
    $shaper = Get-Service -Name PCUploadLimitShaper -ErrorAction SilentlyContinue
    if ($shaper) {
        $serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $shaper.Name
        $expectedImage = '"' + (Join-Path $PSScriptRoot 'PacketLimiter.exe') + '"'
        if ((Get-ItemProperty -LiteralPath $serviceKey).ImagePath -ne $expectedImage) {
            throw 'A different service uses the packet worker name.'
        }
        if ($shaper.Status -ne 'Stopped') { Stop-Service -Name $shaper.Name }
        $serviceName = $shaper.Name
        $shaper.Dispose()
        & (Join-Path ([Environment]::SystemDirectory) 'sc.exe') delete $serviceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove the packet shaper service.' }
    }
    $marker = Join-Path $PSScriptRoot 'PacketDriverOwned'
    if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq '{4EC4289E-7F4B-424C-8EA9-B7AC9850FFBE}') {
        $removeDriver = Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') `
            -ArgumentList '/x {4EC4289E-7F4B-424C-8EA9-B7AC9850FFBE} /quiet /norestart' -WindowStyle Hidden -PassThru -Wait
        if ($removeDriver.ExitCode -notin 0, 1605, 3010) { throw "Windows Packet Filter removal returned $($removeDriver.ExitCode)." }
    }
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false }
    $link = [string](Get-UploadSettings).Shortcut
    $desktopDirectory = if ($link) { Split-Path -Parent $link }
    if ($desktopDirectory -and (Test-Path -LiteralPath $desktopDirectory -PathType Container)) {
        $shortcuts = New-Object -ComObject WScript.Shell
        foreach ($candidate in Get-ChildItem -LiteralPath $desktopDirectory -File -Filter '*.lnk') {
            $shortcut = $shortcuts.CreateShortcut($candidate.FullName)
            if ($shortcut.TargetPath -eq $shellPath -and $shortcut.Arguments -eq ($launchArguments + 'Desktop')) {
                Remove-Item -LiteralPath $candidate.FullName
            }
        }
    }

    if (Test-Path -LiteralPath $uninstallKey) { Remove-Item -LiteralPath $uninstallKey }
    foreach ($name in 'LimiterWindow.ps1','LimiterWindow.xaml','AppCatalog.dll','PacketLimiter.exe','PacketLimiter.status','ndisapi.dll','PacketDriverOwned') {
        $path = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $settingsPath, $lockPath, $PSCommandPath
    if (!(Get-ChildItem -LiteralPath $PSScriptRoot -Force)) { Remove-Item -LiteralPath $PSScriptRoot }
}

if ($Action -eq 'SetRate' -and !$UploadMbps) { throw 'Supply -UploadMbps to set the upload speed.' }
if ($Action -eq 'SetDevice') {
    if (!$UploadMbps -or !$DownloadMbps) { throw 'Supply both PC limits in Mbps.' }
    Set-DeviceLimits $LimitUpload $UploadMbps $LimitDownload $DownloadMbps $Direction
    return
}
if ($Action -eq 'SetDownload') {
    if (!$DownloadMbps) { throw 'Supply -DownloadMbps to set the download speed.' }
    Update-LimiterSettings {
        param($edited)
        if ($LimitDownload -and (Get-PacketShaperStatus) -notin 'Ready', 'Active') { throw 'Packet shaping is unavailable.' }
        $edited.DownloadEnabled = [bool]$LimitDownload
        $edited.DownloadMbps = $DownloadMbps
    }
    Get-UploadLimitStatus
    return
}
if ($Action -in 'SetApp', 'RemoveApp') {
    if (!$AppPath -or ![IO.Path]::IsPathRooted($AppPath) -or [IO.Path]::GetExtension($AppPath) -ne '.exe') { throw 'Supply a full executable path.' }
    if ($Action -eq 'SetApp' -and (!$UploadMbps -or !$DownloadMbps)) { throw 'Supply both app rates in Mbps.' }
    Set-AppLimits $AppPath $LimitUpload $UploadMbps $LimitDownload $DownloadMbps -Remove:($Action -eq 'RemoveApp') -Direction $Direction
    return
}
if ($Action -in 'Enable', 'Disable', 'SetRate', 'StartAtBoot') { Set-UploadLimit $Action $UploadMbps }
if ($Action -in 'Status', 'Enable', 'Disable', 'SetRate', 'StartAtBoot') { Get-UploadLimitStatus; return }
if ($Action -eq 'Uninstall' -and $Quiet) { Remove-UploadLimit; return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Confirm-Uninstall {
    $answer = [Windows.Forms.MessageBox]::Show('Remove your network limits and uninstall Network Throttler?', $caption, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return $false }

    Remove-UploadLimit
    [Windows.Forms.MessageBox]::Show('Network Throttler was uninstalled.', $caption, 'OK', 'Information') | Out-Null
    $true
}

if ($Action -eq 'Uninstall') {
    try { Confirm-Uninstall | Out-Null }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, $caption, 'OK', 'Error') | Out-Null }
    return
}

try { . (Join-Path $PSScriptRoot 'LimiterWindow.ps1') }
catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, $caption, 'OK', 'Error') | Out-Null }
