<#
.SYNOPSIS
Packages files from the project directory into a staging area with short names, a mapping file, and checksums for distribution.

.DESCRIPTION
This script scans the project directory for files and empty directories, including those with long paths.
It generates a staging area where files are assigned short, sequential names and preserved in relative paths.
A `map.json` is written to track original paths and short names.
Empty directories are included with a ShortName of "N/A".
SHA256 checksums are generated for all files.
A final deliverable is created in the `_DomainAutoDeploy4.0_Distribution` folder, containing:
- package.zip (with staged files, map.json, and checksums)
- helper files: README.txt, setup.bat, unpack-and-run.ps1
Logs and error reports are saved to the `logs` directory.

.AUTHOR
Francisco X. Montano III

.NOTES
- Long path support is handled using Robocopy.
- Files are renamed with short aliases for staging and zipped for distribution.
- Checksums are exported in `checksums.sha256` for future validation.
- Requires PowerShell 5.1 or later.
- Temporary files are written to the system TEMP directory and removed after packaging.
- `_ForDistribution` is the final distribution folder for end users.

.PARAMETER None
This script accepts no parameters. All paths are defined internally.

.EXAMPLE
.\Package-Files.ps1

Launches the script interactively and packages all content from the project directory into a staging area and deliverable.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\Package-Files.ps1

Runs the script non-interactively, suitable for automation, scheduled tasks, or elevated execution.

.LINK
https://learn.microsoft.com/en-us/powershell/scripting/developer/help/help-overview

.VERSION
1.1.1
#>

##################################
#   Admin Configured Variables   #
##################################
# None

##################################
#             Logging            #
##################################
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"

    try {
        Add-Content -Path $LogPath -Value $logMessage -ErrorAction Stop
    } catch {
        Write-Warning "Failed to write to log file: $_"
    }

    switch ($Level.ToUpper()) {
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        "WARN"  { Write-Host $Message -ForegroundColor Yellow }
        "INFO"  { if ($VerbosePreference -eq 'Continue') { Write-Host $Message -ForegroundColor Green } }
        Default { Write-Host $Message }
    }
} # Function end

##################################
####  Environmental Variables ####
##################################
$date             = Get-Date -Format yyyyMMdd
$timestamp        = Get-Date -Format "yyyyMMdd-HHmmss"
$hostname         = $env:COMPUTERNAME
$scriptFullPath   = $MyInvocation.MyCommand.Path
$scriptDir        = Split-Path -Path $scriptFullPath -Parent
$basePath         = Split-Path -Path $scriptDir -Parent
$user             = $env:USERNAME
$operatingSystem  = (Get-CimInstance win32_OperatingSystem).Caption

##################################
###           MODULES          ###
##################################
# None

##################################
#######  Global Variables  #######
##################################
$fileMap = @{}
$errors = @()
$counter = 0
$shortNameFormat  = "f{0:D4}{1}"
$logDir           = Join-Path $basePath "logs"
#$tempDir         = Join-Path $env:TEMP ("DomainAutoDeploy-" + [System.Guid]::NewGuid().ToString("N"))
$tempDir          = Join-Path "C:\temp" ("DomainAutoDeploy.tmp")
$mapFilePath      = Join-Path $tempDir "map.json"

##################################
####   Cosmetic Functions    #####
##################################
function MakeTopAndBottom {
    return "# " + ('-' * ($Host.UI.RawUI.BufferSize.Width - 4)) + " #"
} # Function End

function MakeSpaces {
    return "# " + (' ' * ($Host.UI.RawUI.BufferSize.Width - 4)) + " #"
} # Function End

function CenterText {
    param([string]$message)
    $padding = [Math]::Max(0, ($Host.UI.RawUI.BufferSize.Width / 2) - ($message.Length / 2) - 4)
    return "# " + (' ' * $padding) + $message + (' ' * ($Host.UI.RawUI.BufferSize.Width - $padding - $message.Length - 6)) + " #"
} # Function End

function Announcement {
    param([string]$message)
    Write-Host (MakeTopAndBottom)
    Write-Host (MakeSpaces)
    Write-Host (CenterText $message)
    Write-Host (MakeSpaces)
    Write-Host (MakeTopAndBottom)
} # Function End

function PromptForAcknowledgement {
    param([string]$message)
    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message)
    } else {
        Write-Host "$message" -ForegroundColor Yellow 
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')   
    }
} # Function End

##################################
######   Helper Functions   ######
##################################
function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    # Normalize slashes
    $base = $BasePath.TrimEnd('\')
    $full = $FullPath

    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $full.Substring($base.Length).TrimStart('\')
        return $relative -replace '\\', '/'
    }

    throw "Cannot determine relative path for: $FullPath"
} # Function End

function Write-ChecksumsFromMap {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MapFilePath  # Path to map.json
    )

    Write-Host "Generating checksums..." -ForegroundColor Yellow
    
    $checksumPath = Join-Path $tempDir "checksums.sha256"
    $map = Get-Content -Path $MapFilePath | ConvertFrom-Json

    $checksumObjects = @()

    foreach ($fileEntry in @($map.files)) {
        $relativePath = $fileEntry.Path
        $fullPath = Join-Path $basePath $relativePath
        $shortName = $fileEntry.ShortName
        $name = [System.IO.Path]::GetFileName($fullPath)

        if (-not (Test-Path $fullPath)) {
            $Global:errors += "File not found for checksum: $fullPath"
            continue
        }

        try {
            $hash = Get-FileHash -Path $fullPath -Algorithm SHA256
            $checksumObjects += [PSCustomObject]@{
                Name      = $name
                ShortName = $shortName
                Hash      = $hash.Hash
            }
        }
        catch {
            $Global:errors += "Checksum failed for ($fullPath): $_"
        }
    }

    # Export as CSV with Name, ShortName, and Hash
    $checksumObjects | Export-Csv -Path $checksumPath -NoTypeInformation -Encoding UTF8

    Write-Host "Checksums generated!" -ForegroundColor Green
    Write-Host "Checksums.sha256 written with $($checksumObjects.Count) entries" -ForegroundColor Cyan
} # Function End

function Remove-TempDir {
    if (Test-Path $tempDir) {
        # Empty the folder using robocopy, then delete it
        $TempEmpty = "$env:TEMP\_empty"
        $PathToDelete = "C:\Temp\DomainAutoDeploy"
        
        New-Item -ItemType Directory -Path $TempEmpty -Force | Out-Null
        robocopy $TempEmpty $PathToDelete /MIR | Out-Null  # Mirrors empty folder
        Remove-Item $PathToDelete -Force -Recurse          # Now shorter paths
        Remove-Item $TempEmpty -Force -Recurse          # Now shorter paths
        Write-Host "`nRemoved temp directory $tempDir" -ForegroundColor Gray
    }
} # Function End

##################################
#######   Core Functions   #######
##################################
function Initialize-TempDirectory{             # Clear and recreate the stagin directory   
    if(Test-Path $tempDir){
        Write-Host "Preparing temporary directory..." -ForegroundColor Yellow
        Remove-Item $PathToDelete -Force -Recurse | Out-Null
        
        if(Test-Path $tempDir){
            # Empty the folder using robocopy, then delete it
            $TempEmpty = "$env:TEMP\_empty"
            $PathToDelete = $tempDir
        
            New-Item -ItemType Directory -Path $TempEmpty -Force
            $RC = robocopy $TempEmpty $PathToDelete /MIR /V   # Mirrors empty folder
            $exitCode = $LASTEXITCODE
        
            if($exitCode -gt 3){
                throw "Robocopy failed during mirror. Exit code: $exitCode"
            }
        
            Remove-Item $PathToDelete -Force -Recurse       # Now shorter paths
            Remove-Item $TempEmpty -Force -Recurse          # Now shorter paths
        }
    }
    
    if((Test-Path -Path $tempDir) -eq $false){
        New-Item -ItemType Directory -Path $tempDir 
    }
    
    Write-Host "Temporary directory prepared!" -ForegroundColor Green
} # Function End

function Initialize-LogDirectory{
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }
} # Function End

function Generate-MapFileWithRobocopy {
    param(
        [string]$SourceDir,
        [string]$TargetDir
    )
    
    Write-Host "Copying files..." -ForegroundColor Yellow

    $Source = $SourceDir
    $Destination = Join-Path $TargetDir "DAA_Package"
    $logFile = Join-Path $TargetDir ("robocopy-list-" + [guid]::NewGuid().ToString("N") + ".log")

    if((Test-Path -Path $Destination) -eq $false){
        New-Item -ItemType Directory -Path $Destination
    }

    Robocopy.exe $Source $Destination /E /FP /NJH /NJS /LOG:$logFile | Out-Null
    Write-Host "Files Copied!" -ForegroundColor Green
    
    Write-Host "Generating File Objects..." -ForegroundColor Yellow
    $counter = 0
    $allDirs = [System.Collections.Generic.HashSet[string]]::new()
    $dirsWithFiles = [System.Collections.Generic.HashSet[string]]::new()
    $fileObjects = [System.Collections.Generic.List[object]]::new()

    foreach ($line in Get-Content $logFile) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        if ($trim -match '^(Total|Dirs|Files|Bytes|Times|Copied)') { continue }

        if ($trim -match '([A-Za-z]:\\.*)') {
            $fullPath = $matches[1]

            if (Test-Path $fullPath -PathType Leaf) {
                # File
                $ext = [System.IO.Path]::GetExtension($fullPath)
                $shortName = ("f{0:D4}{1}" -f $counter++, $ext)
                $relativePath = Get-RelativePath -BasePath $SourceDir -FullPath $fullPath
                $fileObjects.Add([PSCustomObject]@{
                    Type      = "File"
                    Path      = $relativePath
                    ShortName = $shortName
                })

                # Track parent directories containing files
                $dirsWithFiles.Add((Split-Path $relativePath -Parent)) | Out-Null
                $allDirs.Add((Split-Path $relativePath -Parent)) | Out-Null
            }
            elseif (Test-Path $fullPath -PathType Container) {
                # Directory
                $relativePath = Get-RelativePath -BasePath $SourceDir -FullPath $fullPath
                $allDirs.Add($relativePath) | Out-Null
            }
        }
    }

    # Compute truly empty directories (directories that have no files inside)
    $emptyDirs = $allDirs.Where({ -not $dirsWithFiles.Contains($_) })

    # Add empty directories to fileObjects with ShortName = "N/A"
    foreach ($dir in $emptyDirs) {
        $fileObjects.Add([PSCustomObject]@{
            Type      = "Directory"
            Path      = $dir
            ShortName = "N/A"
        })
    }

    Remove-Item $logFile -ErrorAction SilentlyContinue

    Write-Host "File Objects generated!" -ForegroundColor Green

    return $fileObjects
} # Function End

function Write-MapFile {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$MapFile
    )
    
    # Convert the passed-in map to JSON and write to file
    $MapFile | ConvertTo-Json -Depth 3 | Set-Content -Path $mapFilePath -Encoding UTF8

    # Write summary to host
    Write-Host "`nmap.json written with $($MapFile.files.Count) files and $($MapFile.emptyDirs.Count) empty directories" -ForegroundColor Cyan
} # Function End

function Package-Deliverable {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceDir,

        [Parameter(Mandatory=$true)]
        [PSCustomObject]$MapFile
    )

    Write-Host "Building deliverable..." -ForegroundColor Yellow

    # Paths
    $DistributeDir  = Join-Path $SourceDir "_DomainAutoDeploy4.0_Distribution"
    $PackageZip     = Join-Path $DistributeDir "package.zip"
    $TempPackageDir = Join-Path $tempDir "DAA_Package"

    if (-not (Test-Path $TempPackageDir)) {
        throw "Staging directory not found: $TempPackageDir"
    }

    # Recreate distribution folder
    if (Test-Path $DistributeDir) {
        Remove-Item -Path $DistributeDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DistributeDir | Out-Null

    ########################################
    # Move + Rename files to root
    ########################################
    Write-Host "Flattening and renaming staged files..." -ForegroundColor Yellow

    foreach ($fileEntry in $MapFile.files) {

        $originalPath = Join-Path $TempPackageDir ($fileEntry.Path -replace '/', '\')
        $destinationPath = Join-Path $TempPackageDir $fileEntry.ShortName

        if (-not (Test-Path $originalPath)) {
            Write-Warning "Missing file: $originalPath"
            continue
        }

        try {
            Move-Item -Path $originalPath -Destination $destinationPath -Force
        }
        catch {
            Write-Warning "Move failed for $originalPath : $_"
        }
    }

    ########################################
    # Remove all subdirectories
    ########################################
    $DirectoriesToRemove = Get-ChildItem -Path $TempPackageDir -Directory 
    foreach($Directory in $DirectoriesToRemove){
        # Empty the folder using robocopy, then delete it
        $TempEmpty = "$env:TEMP\_empty"
        $PathToDelete = $Directory.FullName
        
        New-Item -ItemType Directory -Path $TempEmpty -Force | Out-Null
        robocopy $TempEmpty $PathToDelete /MIR | Out-Null  # Mirrors empty folder
        Remove-Item $PathToDelete -Force -Recurse          # Now shorter paths
        Remove-Item $TempEmpty -Force -Recurse          # Now shorter paths
        Write-Host "`nRemoved temp directory $Directory" -ForegroundColor Gray
    }

    Write-Host "Flattening complete." -ForegroundColor Green

    ########################################
    # Create ZIP
    ########################################
    Write-Host "Creating package.zip..." -ForegroundColor Yellow

    Compress-Archive `
        -Path (Join-Path $tempDir "*") `
        -DestinationPath $PackageZip `
        -Force

    Write-Host "package.zip created." -ForegroundColor Green

    ########################################
    # Copy helper files
    ########################################
    $helperFiles = @("README.txt", "setup.bat", "unpack-and-run.ps1")

    foreach ($file in $helperFiles) {
        $source = Join-Path $basePath $file
        if (Test-Path $source) {
            Copy-Item -Path $source -Destination $DistributeDir -Force
        }
    }

    ########################################
    # Cleanup staging directory
    ########################################
    Remove-Item -Path $tempDir -Recurse -Force

    Write-Host "`nDeliverable built successfully!" -ForegroundColor Green
    Write-Host "`nDistribution contents:"
    Get-ChildItem -Path $DistributeDir | Select-Object Name | Format-Table -AutoSize
} # Function End

##################################
#######        MAIN        #######
##################################
function main {
    try {
        clear
        Announcement "Packaging Software..."
        Initialize-TempDirectory
        Initialize-LogDirectory

        $fileObjects = Generate-MapFileWithRobocopy -SourceDir $basePath -TargetDir $tempDir

        $mapFile = [PSCustomObject]@{
            files     = $fileObjects | Where-Object {$_.Type -eq "File"}
            emptyDirs = $fileObjects | Where-Object {($_.Type -eq "Directory") -and ($_.ShortName -eq "N/A")}
        }
        
        Write-MapFile -MapFile $mapfile
        Write-ChecksumsFromMap -MapFilePath $mapFilePath

        Package-Deliverable -SourceDir $basePath -MapFile $mapFile
        Remove-TempDir
    }
    catch{
        Write-Host "ERROR!"
        Remove-Item -Recurse $tempDir
        throw $_.Exception.Message
       
    }
    Write-Host "`nScript Completed" -ForegroundColor Green
} # Function End

main
