============================================================
 DC-Auto Deploy: Domain Controller Deployment Tool
============================================================

Author:        Francisco Xavier Montano III / Team Wildlands
Version:       3.2.0
Date:          2025-09-01
License:       N/A
Contact:       Francisco.Montano@RTX.com
Repository:    N/A

------------------------------------------------------------
DESCRIPTION
------------------------------------------------------------

DC-Auto Deploy is a PowerShell-based automation tool designed to 
streamline the secure deployment of Microsoft Active Directory 
Domain Controllers.

It automatically:
- Installs necessary Windows Server roles and features
- Applies DISA STIG-aligned hardening policies
- Configures baseline auditing and logging
- Enables security controls (e.g., SMB signing, LDAP signing)
- Validates configuration integrity post-deployment

------------------------------------------------------------
PREREQUISITES
------------------------------------------------------------

- Windows Server 2019 / 2022
- PowerShell 5.1 or later
- RSAT Tools (if running remotely)
- Local Administrator or Domain Admin privileges
- Internet access (if downloading updates or modules)
- Execution Policy set to allow script execution:
    Run: Set-ExecutionPolicy RemoteSigned -Scope Process

------------------------------------------------------------
USAGE
------------------------------------------------------------

Run the setup.bat first **as Administrator**

To run the deployment script, run the DC-Auto Deploy.bat **as Administrator**

or alternatively

run the deployment script, open PowerShell **as Administrator** and execute:

```powershell
.\bin\DC Initial SetupX.XX
