# Loaded by the elevated installer. Keep the SDK pinned to the ABI used by the shaper.
function Build-PacketWorker([string] $OutputPath) {
    $sourceDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or !(Test-Path -LiteralPath $compiler)) {
        throw 'Download and per-app shaping require x64 Windows and .NET Framework.'
    }
    & $compiler /nologo /target:exe /platform:x64 /unsafe /optimize+ /r:System.ServiceProcess.dll /r:System.Web.Extensions.dll `
        ('/out:' + $OutputPath) (Join-Path $sourceDirectory 'PacketLimiter.cs') (Join-Path $sourceDirectory 'ConnectionOwners.cs') `
        (Join-Path $sourceDirectory 'AppCatalog.cs') (Join-Path $sourceDirectory 'NetworkMonitor.cs')
    if ($LASTEXITCODE) { throw 'Compiling the packet limiter failed.' }
}

function Update-PacketWorker([string] $InstallFolder) {
    $serviceId = 'PCUploadLimitShaper'
    $binary = Join-Path $InstallFolder 'PacketLimiter.exe'
    $serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $serviceId
    $service = Get-ItemProperty -LiteralPath $serviceKey
    if ($service.ImagePath -ne ('"' + $binary + '"')) { throw 'A different service uses the packet worker name.' }
    $stage = $binary + '.new'
    $backup = $binary + '.previous'
    $replaced = $false
    try {
        Build-PacketWorker $stage
        Stop-Service -Name $serviceId
        [IO.File]::Replace($stage, $binary, $backup)
        $replaced = $true
        Start-Service -Name $serviceId
        Set-Service -Name $serviceId -DisplayName 'Network Throttler Packet Shaper'
        Remove-Item -LiteralPath $backup
    } catch {
        if ($replaced -and (Test-Path -LiteralPath $backup)) {
            Stop-Service -Name $serviceId -ErrorAction SilentlyContinue
            [IO.File]::Replace($backup, $binary, [NullString]::Value)
        }
        Start-Service -Name $serviceId -ErrorAction SilentlyContinue
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage }
    }
}

function Install-PacketSupport([string] $InstallFolder) {
    $serviceId = 'PCUploadLimitShaper'
    $productId = '{4EC4289E-7F4B-424C-8EA9-B7AC9850FFBE}'
    $driverKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $productId
    $marker = Join-Path $InstallFolder 'PacketDriverOwned'
    if (Get-Service -Name $serviceId -ErrorAction SilentlyContinue) { return }

    $stage = Join-Path $InstallFolder ('packet-setup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $createdDriver = $false
    $createdService = $false
    $binary = Join-Path $InstallFolder 'PacketLimiter.exe'
    $dll = Join-Path $InstallFolder 'ndisapi.dll'
    $msiexec = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
    $downloadTool = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
    try {
        $sdk = Join-Path $stage 'tools_bin_x64.zip'
        $sdkUrl = 'https://github.com/wiresock/ndisapi/releases/download/v3.4.8/tools_bin_x64.zip'
        & $downloadTool --fail --silent --show-error --location --proto '=https' --max-time 45 --output $sdk $sdkUrl
        if ($LASTEXITCODE -or (Get-FileHash -LiteralPath $sdk).Hash -ne 'BDF3A51BE513D1465C893E09746C2A74B42AECAC0EE837D03D2A36FCA6C49D85') {
            throw 'Could not verify the Windows Packet Filter SDK archive.'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($sdk)
        try { [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry('ndisapi.dll'), $dll, $false) }
        finally { $archive.Dispose() }

        Build-PacketWorker $binary

        if (!(Test-Path -LiteralPath $driverKey)) {
            $msi = Join-Path $stage 'Windows.Packet.Filter.3.6.2.1.x64.msi'
            $driverUrl = 'https://github.com/wiresock/ndisapi/releases/download/v3.6.2/Windows.Packet.Filter.3.6.2.1.x64.msi'
            & $downloadTool --fail --silent --show-error --location --proto '=https' --max-time 45 --output $msi $driverUrl
            if ($LASTEXITCODE -or (Get-FileHash -LiteralPath $msi).Hash -ne '9C388C0B7F189F7FA98720BAE2CAECF7D64F30910838B80B438ECF8956B8502C' -or
                (Get-AuthenticodeSignature -LiteralPath $msi).Status -ne 'Valid') {
                throw 'Could not verify the signed Windows Packet Filter installer.'
            }
            $installArgs = '/i "' + $msi + '" /passive /norestart'
            $install = Start-Process -FilePath $msiexec -ArgumentList $installArgs -PassThru -Wait
            if ($install.ExitCode -notin 0, 3010) { throw "Windows Packet Filter setup returned $($install.ExitCode)." }
            $createdDriver = $true
            Set-Content -LiteralPath $marker -Value $productId -Encoding ASCII
        }

        $probe = & $binary --probe
        if ($LASTEXITCODE) { throw 'The Windows Packet Filter driver could not be opened.' }
        New-Service -Name $serviceId -BinaryPathName ('"' + $binary + '"') -DisplayName 'Network Throttler Packet Shaper' `
            -Description 'Applies configured inbound and per-app rate limits.' -StartupType Automatic | Out-Null
        $createdService = $true
        Start-Service -Name $serviceId
    } catch {
        if ($createdService) {
            Stop-Service -Name $serviceId -ErrorAction SilentlyContinue
            & (Join-Path ([Environment]::SystemDirectory) 'sc.exe') delete $serviceId | Out-Null
        }
        if ($createdDriver) {
            $uninstall = Start-Process -FilePath $msiexec -ArgumentList "/x $productId /quiet /norestart" -WindowStyle Hidden -PassThru -Wait
            if ($uninstall.ExitCode -in 0, 1605, 3010) { Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue }
        }
        foreach ($path in $binary, $dll) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } }
        throw
    } finally {
        Get-ChildItem -LiteralPath $stage -File | Remove-Item
        Remove-Item -LiteralPath $stage
    }
}
