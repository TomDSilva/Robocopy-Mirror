#Requires -Version 5.0

###############################################################################################################################
#                                                                                                                             #
#  A PowerShell script to mirror files & folders using Robocopy.                                                              #
#                                                                                                                             #
#  THIS IS A POTENTIALLY VERY DANGEROUS SCRIPT, YOU HAVE BEEN WARNED!                                                         #
#  THIS WILL DELETE FILES AT THE DESTINATION THAT DO NOT EXIST AT THE SOURCE!                                                 #
#                                                                                                                             #
#  DISCLAIMER: THIS CODE IS PROVIDED FREE OF CHARGE. UNDER NO CIRCUMSTANCES SHALL I HAVE ANY LIABILITY TO YOU FOR ANY LOSS    #
#  OR DAMAGE OF ANY KIND INCURRED AS A RESULT OF THE USE OF THIS CODE. YOUR USE OF THIS CODE IS SOLELY AT YOUR OWN RISK.      #
#                                                                                                                             #
#  By Tom D'Silva 2020 - https://github.com/TomDSilva                                                                         #
#                                                                                                                             #
###############################################################################################################################

###############################################################################################################################
### Version History                                                                                                         ###
###############################################################################################################################
# 1.0 : First release                                                                                                         #
# 1.1 : Added option to exclude directories                                                                                   #
# 1.2 : Added /MT to multithread, defaults as 8                                                                               #
# 1.3 : 01/01/2023 : Overhaul to bring this script in line with my other Robocopy Backup script available here:               #
#                    https://github.com/TomDSilva/Robocopy-Backup                                                             #
#                    Use of expression building technique via $RobocopyCommand variable to overhaul and simplify logic.       #
#                    Added logic to Set-Credential so that this can run on PS5 minimum instead of PS7.                        #
#                    The script now changes the power setting so the machine doesnt go to sleep (and changes back after).     #
###############################################################################################################################

###############################################################################################################################
### Adjustable Variables                                                                                                    ###
###############################################################################################################################

# If backing up from local then just set to '', otherwise input the name of the remote server hosting the source directory.
# This is used to store credentials for connections correctly via custom functions further below:
$sourceClient = 'ServerName'
# The source folders you want to be backed up.
# Can be local or remote:
$sourceDir = '\\ServerName\Share\FolderName'

# If backing up to local then just set to '', otherwise input the name of the remote server hosting the destination directory:
$destinationClient = 'ServerName'
# !!!MAKE SURE destinationDir IS CORRECT AS IT WILL PURGE FILES THAT DO NOT EXIST AT THE SOURCE!!!
# !!!THE LAST FOLDER ON THE PATH SHOULD MATCH THE FOLDER FROM THE SOURCE!!!
$destinationDir = '\\ServerName\Share\FolderName'

# Set this to just '' if you dont want to exclude any directories
# If you want to exclude multiple directories then seperate them via commas and single quatations such as below:
# $excludedDirArray = '\\ServerName\Share\FolderName\ExcludedFolder1' , '\\ServerName\Share\FolderName\ExcludedFolder2'
[string[]]$excludedDirArray = ''

# Set this to just '' if you dont want to exclude any files.
# If you want to exclude multiple files then seperate them via commas and single quotations such as below:
# $excludedFileArray = '*.log' , '*.txt' , '*.xlxs'
[string[]]$excludedFileArray = ''

# Set this to just '' if you dont want to log
$logLocation = 'D:\'
# Retry attempts in case a file is unable to be read:
$retryAmount = 10
# Wait time in seconds:
$waitAmount = 6

# You probably dont wan't to change these:
# tempLocation needed in case we are running the script from a network share
# as elevation to local admin will not be able to read this script:
$tempLocation = 'C:\Temp'
$dateTime = Get-Date -Format "yy-MM-dd HH-mm-ss"

###############################################################################################################################
### End of Adjustable Variables                                                                                             ###
###############################################################################################################################

###############################################################################################################################
### Main Script - DO NOT CHANGE BELOW HERE                                                                                  ###
###############################################################################################################################

###############################################################################################################################
### Script Location Checker                                                                                                 ###
###############################################################################################################################

# Get the full path of this script
$scriptPath = $MyInvocation.MyCommand.Path
# Remove the "file" part of the path so that only the directory path remains
$scriptPath = Split-Path $scriptPath
# Change location to where the script is being run
Set-Location $scriptPath

###############################################################################################################################
### End of Script Location Checker                                                                                          ###
###############################################################################################################################

# Full path name to the temp script that we will be copying under:
[string]$tempScript = "$tempLocation\$($MyInvocation.MyCommand.Name)"

# If we aren't an admin then run these commands:
If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    # Check if the temp directory exists, if not then creates it
    if (-not (test-path $tempLocation)) {
        New-Item $tempLocation -ItemType "directory"
    }

    # Copy our script to a temp location to be run as admin:
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $tempLocation

    # Relaunch this temp script as an elevated process:
    Start-Process powershell.exe "-File", ('"{0}"' -f $tempScript) -Verb RunAs

    # Exit (this current non admin session)
    exit
}

# Now running elevated so run the rest of the script:

###############################################################################################################################
### Function(s)                                                                                                             ###
###############################################################################################################################

# Helper function that ensures that the most recent powercfg.exe call succeeded.
function Assert-OK { if ($LASTEXITCODE -ne 0) { throw } }

function Find-Credential {
    param( [string]$serverName)
    [string]$storedCreds = cmdkey.exe "/list:Domain:target=$serverName"

    if ($storedCreds -like '* NONE *') {
        Set-Credential($serverName)
    }
}

function Set-Credential {
    param( [string]$serverName)
    $username = Read-Host -Prompt 'Username?'
    $password = Read-Host -Prompt 'Password?' -AsSecureString
    
    # Check to see if we are running with at least PowerShell version 7 (needed for the '-AsPlainText' command to work)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        cmdkey.exe /add:$serverName /user:$username /pass:([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))))
    }
    elseif ($PSVersionTable.PSVersion.Major -ge 7) {
        cmdkey.exe /add:$serverName /user:$username /pass:(ConvertFrom-SecureString -SecureString $password -AsPlainText)
    }
}

###############################################################################################################################
### End of Function(s)                                                                                                      ###
###############################################################################################################################

# To stop the PC sleeping temporarily, define the properties of a custom power scheme, to be created on demand.
$schemeGuid = 'e03c2dc5-fac9-4f5d-9948-0a2fb9009d67' # randomly created with New-Guid
$schemeName = 'Always on'
$schemeDescr = 'Custom power scheme to keep the system awake indefinitely.'

# Determine the currently active power scheme, so it can be restored at the end.
$prevGuid = (powercfg -getactivescheme) -replace '^.+([-0-9a-f]{36}).+$', '$1'
Assert-OK

# Temporarily activate a custom always-on power scheme; create it on demand.
try {
    # Try to change to the custom scheme.
    powercfg -setactive $schemeGuid 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Changing failed -> create the scheme on demand.
        # Clone the 'High performance' scheme.
        $null = powercfg -duplicatescheme SCHEME_MIN $schemeGuid
        Assert-OK
        # Change its name and description.
        $null = powercfg -changename $schemeGuid $schemeName $schemeDescr
        # Activate it
        $null = powercfg -setactive $schemeGuid
        Assert-OK
        # Change all settings to be always on.
        # Note: 
        #   * Remove 'monitor-timeout-ac', 'monitor-timeout-dc' if it's OK
        #     for the *display* to go to sleep.
        #   * If you make changes here, you'll have to run powercfg -delete $schemeGuid 
        #     or delete the 'Always on' scheme via the GUI for changes to take effect.
        #   * On an AC-only machine (desktop, server) the *-ac settings aren't needed.
        $settings = 'monitor-timeout-ac', 'monitor-timeout-dc', 'disk-timeout-ac', 'disk-timeout-dc', 'standby-timeout-ac', 'standby-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc'
        foreach ($setting in $settings) {
            powercfg -change $setting 0 # 0 == Never
            Assert-OK
        }
    }

    # Sanitize string
    if ($logLocation[-1] -eq '\') {
        $logLocation = $logLocation.TrimEnd('\')
    }

    if ($sourceClient -ne '') {
        Find-Credential($sourceClient)
    }

    if ($destinationClient -ne '') {
        Find-Credential($destinationClient)
    }

    $folderName = $sourceDir.Split('\')[-1]

    $robocopyCommand = "Robocopy.exe `"$sourceDir`" `"$destinationDir`" /ZB /MIR /MT /E /R:$retryAmount /W:$waitAmount /TEE /COPY:DT"

    # If logging is turned on.
    if ('' -ne $logLocation) {
        $robocopyCommand = $robocopyCommand + " /LOG:`"$logLocation\Robocopy Log - $folderName - $dateTime.log`""
    }

    # If we are excluding a directory.
    if ('' -ne $excludedDirArray) {
        foreach ($entry in $excludedDirArray) {
            $excludedDir += "`'$entry`' "
        }
        $robocopyCommand = $robocopyCommand + " /XD $excludedDir"
    }

    # If we are excluding files.
    if ('' -ne $excludedFileArray) {
        foreach ($entry in $excludedFileArray) {
            $excludedFile += "`'$entry`' "
        }
        $robocopyCommand = $robocopyCommand + " /XF $excludedFile"
    }

    try {
        Invoke-Expression $robocopyCommand
    }
    catch {
        Write-Output 'SOMETHING WENT WRONG!'
        Write-Warning $error[0]
    }

}
finally {
    # Executes even when the script is aborted with Ctrl-C.
    # Reactivate the previously active power scheme.
    powercfg -setactive $prevGuid

    # If we are using a temporary script, then remove it
    if ($scriptPath -eq (Split-Path $MyInvocation.MyCommand.Path)) {
        Remove-Item -Path $tempScript
    }

    # Wait for the user to acknowledge with the enter key
    Read-Host -Prompt "Press Enter to exit"
}
