<#
.SYNOPSIS
Baselines or deploys an Active Directory environment in accordance with organizational best practices.

.DESCRIPTION
This script automates the deployment and configuration of a domain environment. 
It performs the following actions based on user selection:

- Option 1: Full baseline
    - Validates and installs server roles
    - Updates and stages source files
    - Creates Organizational Units (OUs), groups, and user accounts
    - Updates migration tables
    - Imports Group Policy Objects (GPOs) interactively or automatically, with link options
- Option 2: Only imports GPOs
- Option 3: [Reserved for future functionality]

This script supports interactive control of GPO import (manual vs auto) and linking (enabled/disabled).

.PARAMETER None
This script does not accept parameters; all paths and behavior are controlled internally.

.EXAMPLE
.\domainSetup.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\domainSetup.ps1

.LINK
https://learn.microsoft.com/en-us/powershell/scripting/developer/help/help-overview

.AUTHOR
Francisco X. Montano III

.NOTES
Run as Administrator.
Requires GroupPolicy module and AD PowerShell tools.

.VERSION
4.1.2

.CHANGELOG
- 20250325: Restructured file organization, added environment variables
- 20250326: Separated source files into temp directory
- 20250327: Improved GPO import process, added looping
- 20250811: Added GPO auto/interactive import and link/enable/disable options
- 20250822: Refactored for PowerShell best practices, renamed functions, cleaned up logic
            Enhanced Import-AllGpos with better logging, deduplication, migration table logic, and interactive UX
- 20250825: Updated Main menu defaults for GPO linking and enabling to 'No'; enabled/disabled prompt now conditional on linking choice; added -EnableLinkState parameter to Import-AllGPOs for finer control.
- 20250924: Updated Check-GroupMembership function to add groups to roles and service accounts to applicable groups.
- 20251003: Updated Minimum Required Features
- 20260105: Updated Service Account Creation to include misc information
- 20260114: Updated Auto-Link Feature
- 20260302: Added Import-WMIFilter function
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
#  Environmental Variables       #
##################################
$date             = Get-Date -Format 'yyyyMMdd'
$hostname         = $env:COMPUTERNAME
$scriptFullPath   = $MyInvocation.MyCommand.Path
$binPath          = Split-Path -Path $scriptFullPath -Parent
$basePath         = Split-Path -Path $binPath -Parent
$scriptPath       = $basePath
$userName         = $env:USERNAME
try {
    $operatingSystem = (Get-CimInstance win32_OperatingSystem).Caption
} catch {
    Write-Log "Failed to get OS information: $_" "WARN"
    $operatingSystem = "Unknown"
}
try {
    $domainInfo = Get-ADDomain -Current LocalComputer 
    $domainName = $domainInfo.DistinguishedName
    $dnsDomainName = $domainInfo.DNSRoot
    $netBiosName = $domainInfo.NetBIOSName
} catch {
    Write-Log "Failed to get domain information: $_" "ERROR"
}

##################################
#           MODULES              #
##################################
Try {
    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
} Catch {
    Write-Log "Required modules missing: $_" "ERROR"
}

##################################
#       Global Variables         #
##################################
$binDir                = Join-Path $scriptPath "bin"
$docDir                = Join-Path $scriptPath "doc"
$etcDir                = Join-Path $scriptPath "etc"
$exportDir             = Join-Path $scriptPath "export"
$libDir                = Join-Path $scriptPath "lib"
$logDir                = Join-Path $scriptPath "logs"
$tempDir               = Join-Path $scriptPath "temp" 
$logPath               = Join-Path $logDir "DeployBaseline.log"
$deploymentVersion     = Get-Content (Join-Path $etcDir "current.txt")
$deploymentBinaries    = Join-Path $etcDir "releases\2026.05.01"

##################################
#       Cosmetic  Functions       #
##################################
function New-UiBorderLine {
    return "# " + ('-' * ($Host.UI.RawUI.BufferSize.Width - 4)) + " #"
} # Function end

function New-UiSpacerLine {
    return "# " + (' ' * ($Host.UI.RawUI.BufferSize.Width - 4)) + " #"
} # Function end

function New-UiCenteredText {
    param (
        [string]$Message
    )

    $padding = [Math]::Max(0, ($Host.UI.RawUI.BufferSize.Width / 2) - ($Message.Length / 2) - 4)
    return "# " + (' ' * $padding) + $Message + (' ' * ($Host.UI.RawUI.BufferSize.Width - $padding - $Message.Length - 6)) + " #"
} # Function end

function Show-UiAnnouncement {
    param (
        [string]$Message
    )

    Write-Host (New-UiBorderLine)
    Write-Host (New-UiSpacerLine)
    Write-Host (New-UiCenteredText -Message $Message)
    Write-Host (New-UiSpacerLine)
    Write-Host (New-UiBorderLine)
} # Function end

function Prompt-UserAcknowledgement {
    param (
        [string]$Message
    )

    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message)
    } else {
        Write-Host $Message -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
} # Function end

##################################
#         Core Functions         #
##################################
function Check-ServerRoles {
    try {
        Show-UiAnnouncement -Message "Checking Server Roles..."

        $features = @(
            'AD-Domain-Services',
            'NPAS',
            'VolumeActivation'
        )

        foreach ($feature in $features) {
            write-host "$feature"
            if ((Get-WindowsFeature -Name $feature).InstallState -eq "Installed") {
                Write-Host "$feature is already installed."
            } else {
                Write-Host "$feature not found." -ForegroundColor Red
                Write-Host "Installing..." -ForegroundColor Yellow

                Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null

                Write-Host "$feature installed!" -ForegroundColor Green
            }
        }

        Show-UiAnnouncement -Message "Server Roles Checked!"
    } catch {
        throw $_.Exception.Message
    }
} # Function end

function Update-SourceFiles {
    Show-UiAnnouncement -Message "Modifying Source Files..."

    $nameFile   = Join-Path $deploymentBinaries "Source Files\Source_Name.csv"
    $domainInfo = Import-Csv -Path $nameFile
    $domainInfo
    $sourceDN   = $domainInfo.DistinguishedName
    $sourceDNS  = $domainInfo.DnsRoot

    $inputFiles = Get-ChildItem -Path (Join-Path $deploymentBinaries "Source Files") -File

    foreach ($file in $inputFiles) {
        if ($file.Name -eq "Source_Name.csv") { continue }

        $outputName = $file.Name -replace "^Source_", ""
        $sourcePath = $file.FullName
        $destPath   = Join-Path $tempDir $outputName

        Write-Host "Modifying $sourcePath..." -ForegroundColor Cyan

        (Get-Content -Path $sourcePath) |
            ForEach-Object {
                $_ -replace $sourceDN, $Global:DomainName `
                   -replace $sourceDNS, $Global:DnsDomainName
            } | Set-Content -Path $destPath

        Write-Host "$outputName modified!" -ForegroundColor Green
    }

    Show-UiAnnouncement -Message "Source Files Modified!"
} # Function end

function Check-OrganizationalUnits {
    Show-UiAnnouncement -Message "Checking Organizational Units..."

    $ouFile = Join-Path $tempDir "OUs.csv"

    if (-not (Test-Path $ouFile)) {
        Write-Warning "OU definition file not found: $ouFile"
        return
    }

    $organizationalUnits = Import-Csv -Path $ouFile

    foreach ($ou in $organizationalUnits) {
        $ouName = $ou.Name
        $distinguishedName = $ou.DistinguishedName
        $parentPath = ($distinguishedName -split "," | Select-Object -Skip 1) -join ","

        if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$distinguishedName'" -ErrorAction SilentlyContinue) {
            Write-Host "$ouName already exists." -ForegroundColor Yellow
        }
        else {
            try {
                New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ErrorAction Stop
                Write-Host "$ouName created!" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to create OU ${ouName}: $_"
            }
        }
    }

    Show-UiAnnouncement -Message "Organizational Units Checked!"

} # Function end

function Check-Groups {
    Show-UiAnnouncement -Message "Checking Domain Groups..."

    $groupFile = Join-Path $tempDir "Groups.csv"

    if (-not (Test-Path $groupFile)) {
        Write-Warning "Group definition file not found: $groupFile"
        return
    }

    $groups = Import-Csv -Path $groupFile

    foreach ($group in $groups) {
        $name            = $group.Name
        $samAccountName  = $group.SamAccountName
        $distinguishedName = $group.DistinguishedName
        $path            = ($distinguishedName -split "," | Select-Object -Skip 1) -join ","
        $groupCategory   = $group.GroupCategory
        $groupScope      = $group.GroupScope
        $displayName     = $group.DisplayName
        $description     = $group.Description

        $existingGroup = Get-ADGroup -LDAPFilter "(sAMAccountName=$samAccountName)" -ErrorAction SilentlyContinue

        if ($existingGroup) {
            Write-Host "$name group already exists." -ForegroundColor Yellow
        }
        else {
            try {
                New-ADGroup -Name $name `
                            -SamAccountName $samAccountName `
                            -GroupCategory $groupCategory `
                            -GroupScope $groupScope `
                            -DisplayName $displayName `
                            -Path $path `
                            -Description $description `
                            -ErrorAction Stop

                Write-Host "Created group: $name" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to create group ${name}: $_"
            }
        }
    }

    Show-UiAnnouncement -Message "Domain Groups Checked!"
} # Function end

function Check-Accounts {
    Show-UiAnnouncement -Message "Checking Domain Accounts..."

    $accountFile = Join-Path $tempDir "Accounts.csv"

    if (-not (Test-Path $accountFile)) {
        Write-Warning "Accounts definition file not found: $accountFile"
        return
    }

    $accounts = Import-Csv -Path $accountFile

    # First, check which accounts already exist
    $missingAccounts = @()

    foreach ($account in $accounts) {
        $name = $account.sAMAccountName
        $existingUser = Get-ADUser -LDAPFilter "(sAMAccountName=$name)" -ErrorAction SilentlyContinue

        if (-not $existingUser) {
            $missingAccounts += $account
        }
        else {
            Write-Host "$name already exists." -ForegroundColor Yellow
        }
    }

    if ($missingAccounts.Count -eq 0) {
        Show-UiAnnouncement -Message "All domain accounts already exist. No changes needed."
        return
    }

    # Prompt for password only if there are missing accounts
    $securePassword = Read-Host -AsSecureString "Enter the password for all service accounts"

    foreach ($account in $missingAccounts) {

        $path = ($account.DistinguishedName -split "," | Select-Object -Skip 1) -join ","
        try {
            New-ADUser -AccountPassword $securePassword `
                       -Description $account.Description `
                       -DisplayName $account.DisplayName `
                       -GivenName $account.GivenName `
                       -Name $account.Name `
                       -Enabled $false `
                       -PasswordNeverExpires $true `
                       -Path $path `
                       -SamAccountName $account.sAMAccountName `
                       -Surname $account.Surname `
                       -UserPrincipalName $account.UserPrincipalName `
                       -ErrorAction SilentlyContinue `
                       -Verbose
                       #-OtherAttributes @{ 'description' = $description } `

            Write-Host "Created domain account: $name" -ForegroundColor Green
        } catch {
            Write-Warning "Error while creating accounts: $_"
        }
    }
    
    Show-UiAnnouncement -Message "Domain Accounts Checked and Created!"

} # Function end

function Check-GroupMembership {
    Show-UiAnnouncement -Message "Checking Group Membership..."

    $sourceGroupMembershipFiles = Get-ChildItem $tempDir | Select-Object Name | Where-Object {$_ -like "*members.csv*"}

    foreach($sourceGroupMembershipFile in $sourceGroupMembershipFiles){
        try {
            $SourceFileName = $sourceGroupMembershipFile.Name
            $groupName = ($SourceFileName).replace("_members.csv","")
            $sourceGroupMembershipFilePath = Join-Path $tempDir $SourceFileName
            $groupMembership = Import-Csv -Path $sourceGroupMembershipFilePath
            
            foreach ($entry in $groupMembership) {
                $class     = $entry.objectClass
                $member    = $entry.Name

                if (-not (Get-ADGroup -LDAPFilter "(sAMAccountName=$groupName)" -ErrorAction SilentlyContinue)) {
                    Write-Warning "Group not found: $groupName"
                    continue
                }

                if ($class -eq "group"){
                    if (Get-ADGroupMember -Identity $groupName | Where-Object { $_.SamAccountName -eq $member }) {
                        Write-Host "$member already in group $groupName" -ForegroundColor Yellow
                    } else {
                        Add-ADGroupMember -Identity $groupName -Members $member -ErrorAction Stop
                        Write-Host "$member added to group $groupName" -ForegroundColor Green
                    }
                }

                if ($class -eq "user"){
                    if( -not (Get-ADUser -LDAPFilter "(sAMAccountName=$member)" -ErrorAction SilentlyContinue)){
                        Write-Warning "User not found: $member"
                        continue
                    }
                    if(Get-ADGroupMember -Identity $groupName | Where-Object { $_.SamAccountName -eq $member }){
                        Write-Host "$member already in group $groupName" -ForegroundColor Yellow
                    } else {
                        Add-ADGroupMember -Identity $groupName -Members $member -ErrorAction Stop
                        Write-Host "$member added to group $groupName" -ForegroundColor Green
                    }
                }
       }
        Show-UiAnnouncement -Message "Group Memberships Checked!"

        } catch {
            Write-Warning "Error processing group membership: $_"
        }
    }
        #>
} # Function end

function Delegate-RSOP{
    param(
        [string]$Domain
    )
    
    Show-UiAnnouncement -Message "Checking RSOP Delegation..."
    
    $Group = Get-ADGroup -Filter * | Where-Object{$_.Name -like "*RSOP-RO*"}
    $SID = New-Object System.Security.Principal.SecurityIdentifier($Group.SID)
    $Domain = "AD:$Domain"
    $ACL = Get-Acl $Domain

    $RSOPLoggingGUID  = [guid]"b7b1b3dd-ab09-4242-9e30-9980e5d322f7"
    $RSOPPlanningGUID = [guid]"b7b1b3de-ab09-4242-9e30-9980e5d322f7"
    
    $Identity = [System.Security.Principal.SecurityIdentifier]$SID

    $ACE1 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule $Identity,"ExtendedRight","Allow",$RSOPLoggingGUID
    $ACE2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule $Identity,"ExtendedRight","Allow",$RSOPPlanningGUID
    
    $ACL.AddAccessRule($ACE1)
    $ACL.AddAccessRule($ACE2)

    Set-Acl -Path $Domain -AclObject $ACL

}

function Create-PrivAccount {
    # Placeholder for your implementation
} # Function end

function Import-ADMXFiles {
    Param(
        [string]$Path
    )

    $Templates      = Get-ChildItem -Recurse $Path 
    
    foreach($file in $templates){
        if($file.Extension -eq ".admx"){
            $DestinationDir = "C:\Windows\PolicyDefinitions"
            $Destination = Join-Path $DestinationDir $file.Name
            if(-not(Test-Path $Destination)){
                Write-Host "Copying $file.Name to destination..." -ForegroundColor Yellow
                Copy-Item -Path $file.FullName -Destination $Destination
                Write-Host "$file.Name copied!" -ForegroundColor Green
            }
        }
        
        if($file.Extension -eq ".adml"){
            $DestinationDir = "C:\Windows\PolicyDefinitions\en-US"
            $Destination = Join-Path $DestinationDir $file.Name
            if(-not(Test-Path $Destination)){
                Write-Host "Copying $file.Name to destination..." -ForegroundColor Yellow
                Copy-Item -Path $file.FullName -Destination $Destination
                Write-Host "$file.Name copied!" -ForegroundColor Green
            }
        }
    }

} # Function end

function Import-WMIFilters {
    Param(
        [String]$WMIFilterDir
    )

    if(-not(Test-Path $WMIFilterDir)){
        Write-Host "$WMIFilterDir not found!" -ForegroundColor Red
        return
    }

    Show-UiAnnouncement -Message "Checking WMI Filters..."

    $domainDN = $domainName
    $wmiBasePath = "CN=SOM,CN=WMIPolicy,CN=System,$domainDN"
    $wmiFilters = Get-ChildItem -Path $WMIFilterDir
    
    foreach($filter in $wmiFilters){
        $mofText = Get-Content $filter.FullName -Raw
        $mofText = $mofText -replace "`r?`n", " "

        $somPattern = 'instance of MSFT_SomFilter\s*{(.*?)}\s*;'
        $somMatch = [regex]::Match($mofText, $somPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

        if ($somMatch.Success) {
            $somBody = $somMatch.Groups[1].Value

            # Extract top-level properties
            $somProps = @{}
            foreach ($kv in ($somBody -split ";")) {
                if ($kv -match '(\w+)\s*=\s*"(.*?)"') {
                    $somProps[$matches[1]] = $matches[2] -replace '\\\"','"'   # Convert escaped quotes
                }
            }

            # Extract rules block
            $rulePattern = 'instance of MSFT_Rule\s*{(.*?)}\s*;'
            $rulesMatch = [regex]::Matches($mofText, $rulePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            
  
            foreach($rm in $rulesMatch){
                $ruleText = $rm.Groups[1].Value

                $kvLines = $ruleText -split ";"

                $kvLines = $kvLines | ForEach-Object {$_.Trim()} | Where-Object{$_ -ne ''}
                
                $ruleProps = [PSCustomObject]@{
                    Query           = ($kvLines[0] -split '=',2)[1].Trim() -replace '^"|"$','' -replace '\\\\','\'
                    QueryLanguage   = ($kvLines[1] -split '=',2)[1].Trim() -replace '^"|"$',''
                    TargetNameSpace = ($kvLines[2] -split '=',2)[1].Trim() -replace '^"|"$','' -replace '\\\\','\'
                }
            }
            
            # Combine into a single PSObject
            $filterObject = [PSCustomObject]@{
                Author = $somProps['Author']
                Name = $somProps['Name']
                ID = $somProps['ID']
                Domain = $somProps['Domain']
                Description = $somProps['Description']
                Rules = $ruleProps
            }

            $ID          = $filterObject.ID
            $Name        = $filterObject.Name
           
            if($filterObject.Description -eq $null){
                $Description = "None Given"
            }else{
                $Description = $filterObject.Description
            }
            
            [string]$language  = $filterObject.Rules.QueryLanguage
            [string]$namespace = $filterObject.Rules.TargetNameSpace
            [string]$query     = $filterObject.Rules.Query
            [string]$meta = $query.Length
            
            New-ADObject -Name $ID -Type "msWMI-Som" -Path $wmiBasePath -OtherAttributes @{
                "msWMI-Author" = "DISA"
                "msWMI-ID" = $ID
                "msWMI-Name" = $Name
                "msWMI-Parm1" = $Description
                "msWMI-Parm2" = "1;3;10;$meta;$language;$namespace;$query;"
            }

            Write-Host "Created WMI Filter: $Name" -ForegroundColor Green
        }
    }
} # Function end

function Modify-MigrationTables {
    Show-UiAnnouncement -Message "Modifying Migration Tables..."
    $migrationTablesDir = Join-Path $deploymentBinaries "Source Migration Tables"
    
    $migrationTables = Get-ChildItem -Path $migrationTablesDir

    foreach ($table in $migrationTables) {
        $inputPath = $table.FullName
        $outputPath = Join-Path -Path $tempDir -ChildPath $table.Name
        $content = Get-Content -Path $inputPath
        $modifiedContent = $content -replace "SOURCE_DOMAIN", $DnsDomainName
        $modifiedContent | Set-Content -Path $outputPath
        Write-Host "Modified migration table: $($table.Name)" -ForegroundColor Green
    }

    Show-UiAnnouncement -Message "Migration Tables Modified!"
} # Function end

function Get-GPOBackupFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $backups = @()

    if (-not (Test-Path -Path $Path)) {
        Write-Warning "Path '$Path' does not exist."
        return $null
    }

    $gpoBackupFolders = Get-ChildItem -Path $Path -Directory -Recurse | Where-Object {
        Test-Path (Join-Path $_.FullName 'backup.xml')
    }

    foreach ($folder in $gpoBackupFolders) {
        $backupXmlPath = Join-Path -Path $folder.FullName -ChildPath "backup.xml"
        try {
            [xml]$xml = Get-Content -Path $backupXmlPath -Raw -ErrorAction Stop
            $gpoName = $xml.DocumentElement.GroupPolicyObject.ChildNodes.DisplayName

            if ($gpoName) {
                $backups += [PSCustomObject]@{
                    Name     = $gpoName.InnerText
                    BackupID = $folder.Name
                    Path     = $folder.Parent.FullName
                }
            } else {
                Write-Warning "Missing DisplayName in backup.xml in '$($folder.FullName)'"
            }
        } catch {
            Write-Warning "Failed to read or parse '$backupXmlPath': $_"
        }
    }

    return $backups
} # Function end

function Import-CustomGPO {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath,

        [Parameter(Mandatory)]
        [string]$GPOName,

        [Parameter(Mandatory)]
        [string]$BackupID,  # Changed from [Guid] since it's just a folder name

        [Parameter()]
        [string]$TargetDomain = $env:USERDNSDOMAIN,

        [Parameter()]
        [switch]$ForceOverwrite
    )

    $existingGPO = Get-GPO -Name $GPOName -Domain $TargetDomain -ErrorAction SilentlyContinue
    if ($existingGPO -and -not $ForceOverwrite) {
        Write-Host "GPO '$GPOName' already exists. Skipping (no overwrite)." -ForegroundColor Yellow
        return
    }

    try {
        Import-GPO -BackupId $BackupID -Path $BackupPath -TargetName $GPOName -CreateIfNeeded -Domain $TargetDomain -ErrorAction Stop -MigrationTable $tempDir\Full_Source.migtable
        Write-Host "Successfully imported GPO: $GPOName" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to import GPO '$GPOName': $_"
    }
} # Function end

function Import-AllGPOs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath,

        [Parameter(Mandatory)]
        [string]$TargetDomain,

        [Parameter()]
        [bool]$EnableLinks = $true,

        [Parameter()]
        [bool]$LinkStateEnabled = $true,

        [Parameter()]
        [string]$LinkConfigPath = "$tempDir\GPO-Links.json"
    )

    $gpoBackups = Get-GPOBackupFromPath -Path $BackupPath

    if (-not $gpoBackups -or $gpoBackups.Count -eq 0) {
        Write-Warning "No valid GPO backups found in '$BackupPath'."
        return
    }

    foreach ($gpo in $gpoBackups) {
        try {
            Write-Host "`n--- Importing GPO: $($gpo.Name) ---" -ForegroundColor Cyan

            Import-CustomGPO -GPOName $gpo.Name -BackupId $gpo.BackupID -BackupPath $gpo.Path -TargetDomain $TargetDomain

        } catch {
            Write-Warning "Failed to import GPO '$($gpo.Name)': $_"
        }
    }
} # Function end

function Link-GpoIfConfigured {
    param (
        [Parameter(Mandatory)]
        [string]$GpoName,

        [Parameter(Mandatory)]
        [hashtable]$GpoLinksMap,

        [Parameter(Mandatory)]
        [bool]$LinkStateEnabled
    )

    $linkTarget = $GpoLinksMap[$linkTarget]
    $linkOrder  = $GpoLinksMap[$Order]
    if (-not $linkTarget) {
        Write-Warning "No link target found in config for '$GpoName'. Skipping link."
    } else {
        try {
            $linkState = if($LinkStateEnabled){
                'Yes'
            } else {
                'No'
            }
            Write-Host $linkTarget -ForegroundColor Magenta 
            Write-Host $linkOrder -ForegroundColor Magenta
            New-GPLink -Name $GpoName -Target $linkTarget -LinkEnabled $LinkState -Order $linkOrder
            Write-Host "Linked GPO '$GpoName' to $linkTarget, Enabled: $LinkState" -ForegroundColor Cyan
        } catch {
            Write-Warning "Failed to link GPO '$GpoName' to ${linkTarget}: $_"
        }
    }
} # Function end

function Get-GpoLinkTargets {
    param (
        [string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "GPO link config file not found at: $ConfigPath. GPOs will not be linked."
        return @{}  # Return empty hashtable to avoid errors
    }

    try {
        $jsonContent = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $gpoMap = @{}

        foreach($item in $jsonContent){
            if(-not $gpoMap.ContainsKey($item.GPONickName)){
                $gpoMap[$item.GPONickName] = @()
            }
            
            $gpoMap[$item.GPONickName] += [PSCustomObject]@{
                    TargetDN    = $item.TargetDN
                    Order       = $item.Order
                    TargetType  = $item.TargetType
                }
            }

        return $gpoMap 

    }
    catch {
        Write-Warning "Failed to parse GPO link config file: $_. GPOs will not be linked."
        return @{}
    }
} # Function end

function Cleanup-GPOBackups {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Write-Host "Performing post-import cleanup in '$Path'..."

    # Example: Remove duplicate backup folders
    $allBackups = Get-ChildItem -Path $Path -Directory
    $grouped = $allBackups | Group-Object Name | Where-Object { $_.Count -gt 1 }

    foreach ($group in $grouped) {
        # Keep the most recent, remove the rest
        $ordered = $group.Group | Sort-Object LastWriteTime -Descending
        $toRemove = $ordered | Select-Object -Skip 1

        foreach ($item in $toRemove) {
            try {
                Remove-Item -Path $item.FullName -Recurse -Force
                Write-Host "Removed duplicate backup: $($item.FullName)"
            } catch {
                Write-Warning "Failed to remove: $($item.FullName) — $_"
            }
        }
    }

    Write-Host "Cleanup complete."
} # Function end

function Clean-Folder {
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -Path $Path) {
        Remove-Item -Path (Join-Path -Path $Path -ChildPath '*') -Recurse -Force
        Write-Host "Cleaned folder $Path" -ForegroundColor Green
    }
    else {
        Write-Warning "Path $Path does not exist."
    }
} # Function end

function Developer-Mode{
    #Clear-Host 
    Write-Host "Developer Mode"

    $ouFile = Join-Path $tempDir "OUs.csv"

    if (-not (Test-Path $ouFile)) {
        Write-Warning "OU definition file not found: $ouFile"
        return
    }
    
    $organizationalUnits = Import-Csv -Path $ouFile

    foreach ($ou in $organizationalUnits) {
        $ouName = $ou.Name
        Write-Host $ouName -ForegroundColor Cyan
        $distinguishedName = $ou.DistinguishedName
        $distinguishedName
        $parentPath = ($distinguishedName -split "," | Select-Object -Skip 1) -join ","
        $parentPath
        $description = $ou.Description
        $description
    }
    Wait-Event
} # Function end

##################################
#         Main Function          #
##################################
function Main {
    while ($true) {
        Clear-Host
        Show-UiAnnouncement -Message "Baseline Deployment Menu"
        Write-Host "1) Full Automated Baseline Deployment (Includes interactive GPO import)"
        Write-Host "2) Automated Import GPOs only"
        Write-Host "3) Other option (e.g., Cleanup, Report, etc.)"
        Write-Host "Q) Quit"

        $selection = Read-Host "Select an option"

        switch ($selection.ToUpper()) {
            '1' {
                Show-UiAnnouncement -Message "Starting Full Baseline Deployment"

                # Deployment steps
                Check-ServerRoles
                Update-SourceFiles
                Check-OrganizationalUnits
                Check-Groups
                Check-Accounts
                Check-GroupMembership
                Create-PrivAccount
                Import-ADMXFiles -Path "$deploymentBinaries\ADMX Templates"
                Import-WMIFilters -WMIFilterDir "$deploymentBinaries\WMI Filters"
                Modify-MigrationTables

                # Prompt for linking (default NO)
                $enableLinking = Read-Host "Do you want to LINK imported GPOs? (Y/N) [Default: N]"
                if ([string]::IsNullOrWhiteSpace($enableLinking)) {
                    $enableLinking = 'N'
                }
                $shouldLink = $enableLinking -match '^y'

                # Only prompt for enabled state if linking is enabled
                $linkEnabled = $false
                if ($shouldLink) {
                    $enableLinkState = Read-Host "Should linked GPOs be ENABLED? (Y/N) [Default: N]"
                    if ([string]::IsNullOrWhiteSpace($enableLinkState)) {
                        $enableLinkState = 'N'
                    }
                    $linkEnabled = $enableLinkState -match '^y'
                }

                $groupPolicyObjectsDir = Join-Path $deploymentBinaries "Source GPOs"

                Import-AllGPOs -BackupPath $groupPolicyObjectsDir -TargetDomain $Global:dnsDomainName

                Clean-Folder -Path $TempDir
                Show-UiAnnouncement -Message "Baseline Deployment Completed"
                Read-Host -Prompt "Press Enter to continue..."
            }
            '2' {
                Show-UiAnnouncement -Message "Starting GPO Import Only"

                $enableLinking = Read-Host "Do you want to LINK imported GPOs? (Y/N) [Default: N]"
                if ([string]::IsNullOrWhiteSpace($enableLinking)) {
                    $enableLinking = 'N'
                }
                $shouldLink = $enableLinking -match '^y'

                # Only prompt for enabled state if linking is enabled
                $linkEnabled = $false
                if ($shouldLink) {
                    $enableLinkState = Read-Host "Should linked GPOs be ENABLED? (Y/N) [Default: N]"
                    if ([string]::IsNullOrWhiteSpace($enableLinkState)) {
                        $enableLinkState = 'N'
                    }
                    $linkEnabled = $enableLinkState -match '^y'
                }

                $groupPolicyObjectsDir = Join-Path $deploymentBinaries "Source GPOs"

                Import-AllGPOs -BackupPath $groupPolicyObjectsDir -TargetDomain $Global:dnsDomainName

                Read-Host -Prompt "Press Enter to continue..."
            }
            '3' {
                Show-UiAnnouncement -Message "Option 3 Selected - Implement your logic here"
                Read-Host -Prompt "Press Enter to continue..."
            }
            'D' {
                Developer-Mode
                Wait-Event
            }
            'Q' {
                Write-Host "Exiting..."
                return
            }
            Default {
                Write-Warning "Invalid selection. Please choose 1, 2, 3, or Q."
                Read-Host -Prompt "Press Enter to continue..."
            }
        }
    }
} # Function end


# Execute Main function
Main
