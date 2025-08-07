<#
.SYNOPSIS
  AutoCAD installer with correct working directory and extended timeout.
#>

[CmdletBinding()]
param()

$CacheRoot = '\\casd-wdds\IntuneApps'
$App = @{
    Name           = 'AutoCAD'
    Url            = 'https://casdintuneblobstorage.blob.core.windows.net/intuneapps/AutoCAD.zip'
    FileName       = 'AutoCAD.zip'
    InnerInstaller = 'image\Installer.exe'
    SilentArgs     = '-i deploy --offline_mode -q -o "image\Collection.xml" --installer_version "2.15.0.546"'
    AllowReboot    = $false
}
$LogFile = "$env:ProgramData\Install-Apps.log"
New-Item -Path (Split-Path $LogFile) -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [string]$M,
        [ValidateSet('INFO','WARN','ERROR')][string]$L = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$ts [$L] $M" | Out-File $LogFile -Append
    Write-Verbose "${L}: ${M}"
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Please run as Administrator.'; exit 1
}

function Download-File {
    param([string]$U,[string]$D)
    Write-Log "Downloading $U → $D"
    Invoke-WebRequest -Uri $U -OutFile $D -UseBasicParsing -ErrorAction Stop
    Write-Log 'Download succeeded.'
}

function Install-AutoCAD {
    Write-Log "=== Starting AutoCAD install ==="

    $shareFolder = Join-Path $CacheRoot $App.Name
    $zipOnShare  = Join-Path $shareFolder $App.FileName
    $shareInner  = Join-Path $shareFolder $App.InnerInstaller

    $tempZip     = Join-Path $env:TEMP $App.FileName
    $localRunDir = Join-Path $env:TEMP ($App.Name + '_local')
    $extractDir  = Join-Path $env:TEMP ($App.Name + '_extract')

    $installerExe = $null
    $workDir      = $null

    # 1) Pre-extracted on share?
    if (Test-Path $shareInner) {
        Write-Log "Using pre-extracted share contents"
        Remove-Item $localRunDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item $localRunDir -ItemType Directory | Out-Null
        Copy-Item (Join-Path $shareFolder '*') -Destination $localRunDir -Recurse -Force
        $installerExe = Join-Path $localRunDir $App.InnerInstaller
        $workDir      = $localRunDir
    }

    # 2) ZIP fallback
    if (-not $installerExe) {
        if (Test-Path $zipOnShare) {
            Write-Log "ZIP found on share: $zipOnShare"
            Copy-Item $zipOnShare -Destination $tempZip -Force
        } else {
            Write-Log "Downloading ZIP from blob to $tempZip"
            Download-File $App.Url $tempZip
            if (-not (Test-Path $shareFolder)) { New-Item $shareFolder -ItemType Directory -Force | Out-Null }
            Copy-Item $tempZip -Destination $zipOnShare -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item $extractDir -ItemType Directory | Out-Null
        Write-Log "Extracting ZIP → $extractDir"
        Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force
        $installerExe = Join-Path $extractDir $App.InnerInstaller
        $workDir      = $extractDir
    }

    if (-not (Test-Path $installerExe)) {
        throw "Cannot find Installer.exe at $installerExe"
    }

    Write-Log "Running installer from root folder: $workDir"
    Write-Log "Command: $installerExe $($App.SilentArgs)"
    $proc = Start-Process -FilePath $installerExe `
                          -ArgumentList $App.SilentArgs `
                          -WorkingDirectory $workDir `
                          -PassThru -WindowStyle Hidden

    Write-Log "Waiting up to 3 600 000 ms (60 minutes) for the installer to complete"
    if (-not $proc.WaitForExit(3600000)) {
        $proc.Kill()
        throw "Installer timed out after 60 minutes"
    }
    if ($proc.ExitCode -ne 0) {
        throw "Installer returned exit code $($proc.ExitCode)"
    }
    Write-Log 'Install succeeded.'

    Remove-Item $tempZip    -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $localRunDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($App.AllowReboot) {
        Restart-Computer -Force
    }
}

try {
    Install-AutoCAD
    Write-Log 'Done.'
    exit 0
} catch {
    Write-Log "FAILED: $_" 'ERROR'
    exit 1
}
