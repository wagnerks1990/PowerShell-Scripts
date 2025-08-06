<#
.SYNOPSIS
    Installs an application from a specified URL, supporting MSI, EXE, and ZIP formats.
.DESCRIPTION
    Downloads and installs an application, using a network cache if available, with fallback to local download. Copies the entire network cache directory to the local cache under the application name, deletes the temporary ZIP file from the network cache after extraction, performs cleanup of local files and temporary local ZIP files, and supports advanced features like logging, hash verification, pre/post scripts, and Intune integration. Network cache files (except the temporary ZIP) are preserved for multi-user access.
.PARAMETER SourceUrl
    URL of the installer file (MSI, EXE, or ZIP).
.PARAMETER AppName
    Name of the application for caching purposes.
.PARAMETER InstallerFile
    Name of the installer file inside ZIP or direct file, including subdirectories if applicable.
.PARAMETER ExeSilentArgs
    Silent installation arguments for EXE installers.
.PARAMETER MsiSilentArgs
    Silent installation arguments for MSI installers.
.PARAMETER IntuneProgramDir
    Local directory for temporary files.
.PARAMETER LogFilePath
    Path for the log file.
.PARAMETER FileHash
    Optional hash for file integrity verification.
.PARAMETER HashAlgorithm
    Hash algorithm for verification (default: SHA256).
.PARAMETER AllowReboot
    If specified, allows automatic reboot if required by installer.
.PARAMETER PreInstallScript
    Path to a script to run before installation.
.PARAMETER PostInstallScript
    Path to a script to run after installation.
.EXAMPLE
    .\universal-installer.ps1 -SourceUrl "https://example.com/app.msi" -AppName "MyApp" -InstallerFile "app.msi" -MsiSilentArgs "/qn" -LogFilePath "C:\Logs\app.log"
#>

param (
    [ValidateScript({$_ -match '^https?://'} )][System.String]$SourceUrl           = "REPLACEME",
    [ValidateNotNullOrEmpty()][System.String]$AppName             = "REPLACEME",
    [ValidateNotNullOrEmpty()][System.String]$InstallerFile       = "REPLACEME",
    [System.String]$ExeSilentArgs       = "/VERYSILENT",
    [System.String]$MsiSilentArgs       = "/qn",
    [ValidateScript({Test-Path $_ -IsValid})][System.String]$IntuneProgramDir    = "$env:APPDATA\Intune",
    [System.String]$LogFilePath         = "$env:APPDATA\Intune\$AppName.log",
    [System.String]$FileHash            = "",
    [System.String]$HashAlgorithm       = "SHA256",
    [switch]$AllowReboot,
    [System.String]$PreInstallScript    = "",
    [System.String]$PostInstallScript   = ""
)

# Derive file details
$FileName = [System.IO.Path]::GetFileName($SourceUrl)
$SourceExtension = [System.IO.Path]::GetExtension($FileName).TrimStart('.').ToLower()
$NetworkParent = "\\casd-wds\IntuneApps"
$NetworkCacheDir = "$NetworkParent\$AppName"
$TempNetworkFile = "$NetworkCacheDir\$FileName"
$NetworkInstallerPath = "$NetworkCacheDir\$InstallerFile"

# Local installer path (include AppName in path)
$LocalInstallerPath = "$IntuneProgramDir\$AppName\$InstallerFile"

# Trusted domains for security
$trustedDomains = @("casdintuneblobstorage.blob.core.windows.net")

# Logging function
function Write-Log {
    param ([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] $Message"
    Write-Host $LogMessage
    try {
        Add-Content -LiteralPath $LogFilePath -Value $LogMessage -ErrorAction Stop
    } catch {
        Write-Host "Failed to write to log file ${LogFilePath}: $_"
    }
}

# Function for file removal with retry
function Remove-FileWithRetry {
    param ([string]$Path, [int]$MaxRetries = 3, [int]$DelayMs = 1000)
    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-Log "Removed: $Path"
            return
        } catch {
            $retryCount++
            If ($retryCount -eq $MaxRetries) {
                Write-Log "Failed to remove ${Path}: $_ after $MaxRetries retries"
                return
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# Function for download
function Invoke-Download {
    param ([string]$SourceUrl, [string]$Destination, [bool]$IsNetwork = $false)
    Write-Log "Downloading ${SourceUrl} to ${Destination}..."
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($SourceUrl, $Destination)
        Write-Log "Download completed using WebClient."
    } catch {
        Write-Log "WebClient download failed: $_ Falling back to BitsTransfer."
        Start-BitsTransfer -Source $SourceUrl -Destination $Destination -ErrorAction Stop
        Write-Log "Download completed using BitsTransfer."
    }

    # Verify the file exists and is not empty
    If (-not (Test-Path -LiteralPath $Destination)) {
        throw "Downloaded file not found at ${Destination}."
    }
    $fileInfo = Get-Item -LiteralPath $Destination
    If ($fileInfo.Length -eq 0) {
        throw "Downloaded file at ${Destination} is empty."
    }
    Write-Log "Downloaded file size: $($fileInfo.Length) bytes"

    # Hash verification
    If ($FileHash) {
        $computedHash = (Get-FileHash -LiteralPath $Destination -Algorithm $HashAlgorithm -ErrorAction Stop).Hash
        If ($computedHash -ne $FileHash) {
            throw "Hash mismatch for ${Destination}. Expected: $FileHash, Got: $computedHash"
        }
        Write-Log "Hash verification passed for ${Destination}."
    }
}

# Function for extraction (ZIP handling with subfolder search)
function Invoke-Extraction {
    param ([string]$ArchivePath, [string]$DestinationPath, [string]$InstallerFile, [bool]$IsNetwork = $false)
    Write-Log "Extracting ${ArchivePath} to ${DestinationPath}..."
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force -ErrorAction Stop
        Write-Log "Extraction completed."
        # Remove the ZIP file (local or network)
        Remove-FileWithRetry -Path $ArchivePath
        # Search for the installer recursively
        $foundInstaller = Get-ChildItem -LiteralPath $DestinationPath -Filter ([System.IO.Path]::GetFileName($InstallerFile)) -Recurse -File -ErrorAction Stop | Select-Object -First 1
        If ($foundInstaller) {
            # Return the relative path from DestinationPath
            $relativePath = $foundInstaller.FullName.Substring($DestinationPath.Length + 1)
            Write-Log "Found installer in ZIP: $relativePath"
            return $relativePath
        } Else {
            # Log directory contents for debugging
            Write-Log "Installer ${InstallerFile} not found in extracted files. Listing contents of ${DestinationPath}:"
            Get-ChildItem -LiteralPath $DestinationPath -Recurse | ForEach-Object { Write-Log $_.FullName }
            throw "Installer ${InstallerFile} not found in extracted files."
        }
    } catch {
        Write-Error "Failed to extract ${ArchivePath}. Error: $_"
        exit 1
    }
}

# Function for installation
function Invoke-Install {
    param ([string]$InstallerPath, [string]$InstallerExtension, [string]$MsiSilentArgs, [string]$ExeSilentArgs)
    Write-Log "Installing ${InstallerExtension}: $InstallerPath..."
    try {
        If ($InstallerExtension -eq 'msi') {
            $process = Start-Process "msiexec.exe" -ArgumentList "/i `"$InstallerPath`" $MsiSilentArgs" -Wait -PassThru -ErrorAction Stop
            If ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                throw "MSI installation failed with exit code: $($process.ExitCode)"
            }
            If ($process.ExitCode -eq 3010) {
                Write-Log "MSI installation requires a reboot."
                If ($AllowReboot) {
                    Write-Log "Initiating reboot as required by installer."
                    Restart-Computer -Force
                }
                exit 3010  # Intune-compatible reboot code
            }
        } ElseIf ($InstallerExtension -eq 'exe') {
            $process = Start-Process $InstallerPath -ArgumentList $ExeSilentArgs -Wait -PassThru -ErrorAction Stop
            If ($process.ExitCode -ne 0) {
                throw "EXE installation failed with exit code: $($process.ExitCode)"
            }
        }
    } catch {
        Write-Error "Failed to install ${InstallerExtension}: $InstallerPath. Error: $_"
        exit 1
    }
}

# Function for cleanup (only local files and local temporary ZIPs)
function Invoke-Cleanup {
    param ([string]$LocalInstallerPath, [string]$TempLocalFile, [string]$IntuneProgramDir, [string]$LogFilePath)
    Write-Log "Performing cleanup of local files and temporary local ZIPs..."
    try {
        # Remove local installer directory
        $localInstallerDir = [System.IO.Path]::GetDirectoryName($LocalInstallerPath)
        If (Test-Path -LiteralPath $localInstallerDir) {
            Remove-Item -LiteralPath $localInstallerDir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed local installer directory: $localInstallerDir"
        }

        # Remove temporary local ZIP file if it exists
        If (Test-Path -LiteralPath $TempLocalFile) {
            Remove-FileWithRetry -Path $TempLocalFile
        }

        # Remove local directory if empty
        If (Test-Path -LiteralPath $IntuneProgramDir) {
            $localDirItems = Get-ChildItem -LiteralPath $IntuneProgramDir -ErrorAction SilentlyContinue
            If (-not $localDirItems) {
                Remove-Item -LiteralPath $IntuneProgramDir -Force -ErrorAction Stop
                Write-Log "Removed empty local directory: $IntuneProgramDir"
            }
        }

        # Preserve log
        If (Test-Path -LiteralPath $LogFilePath) {
            $permanentLogDir = "C:\Logs\Intune"
            If (-not (Test-Path -LiteralPath $permanentLogDir)) {
                New-Item -Path $permanentLogDir -ItemType Directory -Force | Out-Null
            }
            $newLogName = "$AppName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
            Copy-Item -LiteralPath $LogFilePath -Destination "$permanentLogDir\$newLogName" -Force
            Write-Log "Copied log to ${permanentLogDir}\$newLogName"
            # Remove original log if local dir is not preserved
            Remove-FileWithRetry -Path $LogFilePath
        }
    } catch {
        Write-Log "Cleanup failed: $_"
    }
}

# Global try/catch
try {
    # Validate source URL domain
    $uri = [Uri]$SourceUrl
    If (-not ($trustedDomains -contains $uri.Host)) {
        Write-Log "Source URL ${SourceUrl} is not from a trusted domain."
        exit 1
    }

    # Check admin privileges if needed
    If ($SourceExtension -eq 'msi' -or $SourceExtension -eq 'exe') {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        If (-not $isAdmin) {
            Write-Log "Installation requires administrative privileges."
            exit 1
        }
    }

    # Check for Intune context
    $isIntune = Test-Path "$env:ProgramData\Microsoft\IntuneManagementExtension"
    If ($isIntune) {
        Write-Log "Running in Intune context."
    }

    # Prerequisite: Disk space check
    $minDiskSpaceMB = 500
    $drive = Split-Path $IntuneProgramDir -Qualifier
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'"
    If ($disk.FreeSpace / 1MB -lt $minDiskSpaceMB) {
        Write-Log "Insufficient disk space on ${drive}. Required: $minDiskSpaceMB MB, Available: $($disk.FreeSpace / 1MB) MB"
        exit 1
    }
    Write-Log "Disk space check passed: $($disk.FreeSpace / 1MB) MB available."

    # Ensure local cache directory exists
    If (-not (Test-Path -LiteralPath $IntuneProgramDir)) {
        New-Item -Path $IntuneProgramDir -ItemType Directory -Force -Confirm:$False | Out-Null
        Write-Log "Created local directory: $IntuneProgramDir"
    }

    # Run pre-install script
    If ($PreInstallScript -and (Test-Path -LiteralPath $PreInstallScript)) {
        Write-Log "Running pre-install script: $PreInstallScript"
        try {
            & $PreInstallScript
        } catch {
            Write-Log "Pre-install script failed: $_"
            exit 1
        }
    }

    # Local download function
    function Invoke-LocalDownload {
        $TempLocalFile = "$IntuneProgramDir\$FileName"

        # Check if the app installer is already available locally
        If (-not (Test-Path -LiteralPath $LocalInstallerPath)) {
            Invoke-Download -SourceUrl $SourceUrl -Destination $TempLocalFile

            # If it's a ZIP, extract the entire content
            If ($SourceExtension -eq 'zip') {
                $script:LocalInstallerPath = Invoke-Extraction -ArchivePath $TempLocalFile -DestinationPath "$IntuneProgramDir\$AppName" -InstallerFile $InstallerFile
                $script:LocalInstallerPath = "$IntuneProgramDir\$AppName\$script:LocalInstallerPath"
            } Else {
                # For direct MSI/EXE, rename/move if needed
                If ($FileName -ne $InstallerFile) {
                    Write-Log "Renaming ${TempLocalFile} to ${InstallerFile}..."
                    $localInstallerDir = [System.IO.Path]::GetDirectoryName($LocalInstallerPath)
                    If (-not (Test-Path -LiteralPath $localInstallerDir)) {
                        New-Item -Path $localInstallerDir -ItemType Directory -Force -Confirm:$False | Out-Null
                        Write-Log "Created local installer directory: $localInstallerDir"
                    }
                    Rename-Item -LiteralPath $TempLocalFile -NewName $InstallerFile -Force -ErrorAction Stop
                }
                $script:LocalInstallerPath = "$IntuneProgramDir\$AppName\$InstallerFile"
            }
        }
        return $LocalInstallerPath
    }

    # Attempt to use network cache if available
    $useNetwork = $true
    $InstallerPath = $LocalInstallerPath
    If (Test-Path -LiteralPath $NetworkParent) {
        Write-Log "Network share ${NetworkParent} is accessible."
        try {
            # Ensure network cache directory exists
            If (-not (Test-Path -LiteralPath $NetworkCacheDir)) {
                New-Item -Path $NetworkCacheDir -ItemType Directory -Force -Confirm:$False | Out-Null
                Write-Log "Created network directory: $NetworkCacheDir"
            }

            # Check if the app installer is already available in the network share
            If (-not (Test-Path -LiteralPath $NetworkInstallerPath)) {
                Invoke-Download -SourceUrl $SourceUrl -Destination $TempNetworkFile -IsNetwork $true

                # If it's a ZIP, extract
                If ($SourceExtension -eq 'zip') {
                    $script:NetworkInstallerPath = Invoke-Extraction -ArchivePath $TempNetworkFile -DestinationPath $NetworkCacheDir -InstallerFile $InstallerFile -IsNetwork $true
                    $script:NetworkInstallerPath = "$NetworkCacheDir\$script:NetworkInstallerPath"
                } Else {
                    # For direct MSI/EXE, rename/move if needed
                    If ($FileName -ne $InstallerFile) {
                        Write-Log "Renaming ${TempNetworkFile} to ${InstallerFile}..."
                        $networkInstallerDir = [System.IO.Path]::GetDirectoryName($NetworkInstallerPath)
                        If (-not (Test-Path -LiteralPath $networkInstallerDir)) {
                            New-Item -Path $networkInstallerDir -ItemType Directory -Force -Confirm:$False | Out-Null
                            Write-Log "Created network installer directory: $networkInstallerDir"
                        }
                        Rename-Item -LiteralPath $TempNetworkFile -NewName $InstallerFile -Force -ErrorAction Stop
                    }
                    $script:NetworkInstallerPath = "$NetworkCacheDir\$InstallerFile"
                }
            }

            # Verify the installer exists after processing
            If (-not (Test-Path -LiteralPath $NetworkInstallerPath)) {
                Write-Log "Listing files in ${NetworkCacheDir}:"
                Get-ChildItem -LiteralPath $NetworkCacheDir -Recurse | ForEach-Object { Write-Log $_.FullName }
                throw "Installer not found at ${NetworkInstallerPath} after processing."
            }

            # Copy the entire network cache directory to local under AppName
            Write-Log "Copying entire network directory ${NetworkCacheDir} to ${IntuneProgramDir}\${AppName}..."
            Write-Log "Listing files in ${NetworkCacheDir} before copy:"
            Get-ChildItem -LiteralPath $NetworkCacheDir -Recurse | ForEach-Object { Write-Log $_.FullName }
            Copy-Item -LiteralPath $NetworkCacheDir -Destination "$IntuneProgramDir\$AppName" -Recurse -Force -ErrorAction Stop
            Write-Log "Listing files in ${IntuneProgramDir}\${AppName} after copy:"
            Get-ChildItem -LiteralPath "$IntuneProgramDir\$AppName" -Recurse | ForEach-Object { Write-Log $_.FullName }
        } catch {
            Write-Log "Network cache operation failed: $_ Falling back to local download."
            $useNetwork = $false
            $InstallerPath = Invoke-LocalDownload
        }
    } Else {
        Write-Log "Network share ${NetworkParent} is unavailable. Using local download."
        $useNetwork = $false
        $InstallerPath = Invoke-LocalDownload
    }

    # Verify the installer exists after processing
    If (-not (Test-Path -LiteralPath $InstallerPath)) {
        Write-Log "Installer not found at ${InstallerPath} after processing."
        Write-Log "Listing files in ${IntuneProgramDir}:"
        Get-ChildItem -LiteralPath $IntuneProgramDir -Recurse | ForEach-Object { Write-Log $_.FullName }
        exit 1
    }

    # Determine installer type and install
    $InstallerExtension = [System.IO.Path]::GetExtension($InstallerFile).TrimStart('.').ToLower()
    Invoke-Install -InstallerPath $InstallerPath -InstallerExtension $InstallerExtension -MsiSilentArgs $MsiSilentArgs -ExeSilentArgs $ExeSilentArgs

    # Run post-install script
    If ($PostInstallScript -and (Test-Path -LiteralPath $PostInstallScript)) {
        Write-Log "Running post-install script: $PostInstallScript"
        try {
            & $PostInstallScript
        } catch {
            Write-Log "Post-install script failed: $_"
            exit 1
        }
    }

    # Cleanup (local files and local temporary ZIPs only)
    $TempLocalFile = "$IntuneProgramDir\$FileName"
    Invoke-Cleanup -LocalInstallerPath $LocalInstallerPath -TempLocalFile $TempLocalFile -IntuneProgramDir $IntuneProgramDir -LogFilePath $LogFilePath

    Write-Log "Installation and cleanup completed successfully."
    exit 0
} catch {
    Write-Log "Unexpected error occurred: $_"
    exit 1
}