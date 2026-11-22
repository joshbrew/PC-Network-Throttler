$ErrorActionPreference = 'Stop'
$entry = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PCUploadLimit'
$install = Get-ItemProperty -LiteralPath $entry -ErrorAction SilentlyContinue
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$supportedFolders = @((Join-Path $programFiles 'Network Throttler'), (Join-Path $programFiles 'PC Upload Limit'))
if ($install.InstallLocation -notin $supportedFolders) {
    exit 2
}

$control = Join-Path $install.InstallLocation 'UploadLimit.ps1'
if (!(Test-Path -LiteralPath $control -PathType Leaf)) { throw 'The installed launcher is missing. Open Install.cmd to run setup again.' }
$shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $control + '" -Action Desktop'
Write-Output 'Opening Network Throttler. Windows may ask for administrator approval.'
Start-Process -FilePath $shell -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory ([Environment]::SystemDirectory)
