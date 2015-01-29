#User variables
$SystemPrepMasterScriptUrl = 'https://s3.amazonaws.com/systemprep/MasterScripts/SystemPrep-WindowsMaster.ps1'
$SourceIsS3Bucket = $true
$SystemPrepParams = @{
    AshRole = "Workstation"
    NetBannerLabel = "Unclass"
    SaltStates = "Highstate"
    NoReboot = $false
    SourceIsS3Bucket = $SourceIsS3Bucket
}

#System variables
$DateTime = $(get-date -format "yyyyMMdd_HHmm_ss")
$ScriptName = $MyInvocation.mycommand.name
$SystemPrepDir = "${env:SystemDrive}\SystemPrep"
$SystemPrepLogFile = "${SystemPrepDir}\SystemPrep-Log_${DateTime}.txt"

function log {
	[CmdLetBinding()]
	Param(
		[Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] $LogMessage
	)
	PROCESS {
		#Writes the input $LogMessage to the log file $SystemPrepLogFile.
		Add-Content -Path $SystemPrepLogFile -Value "$(get-date -format `"yyyyMMdd_HHmm_ss`"): ${ScriptName}: ${LogMessage}"
	}
}

function Download-File {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string] $Url,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $SaveTo,
        [Parameter(Mandatory=$false,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [switch] $SourceIsS3Bucket
    )
    PROCESS {
        if ($SourceIsS3Bucket) {
            Write-Output "Downloading from S3 bucket and saving to: ${SaveTo}"
            $SplitUrl = $Url.split('/') | where { $_ -notlike "" }
            $BucketName = $SplitUrl[2]
            $Key = $SplitUrl[3..($SplitUrl.count-1)] -join '/'
            Read-S3Object -BucketName $BucketName -Key $Key -File $SaveTo 2>&1
        }
        else {
            Write-Output "Downloading from HTTP host and saving to: ${SaveTo}"
            New-Item "${SaveTo}" -ItemType "file" -Force > $null
            (new-object net.webclient).DownloadFile("${Url}","${SaveTo}") 2>&1
        }
    }
}

if (-Not (Test-Path $SystemPrepDir)) { New-Item -Path $SystemPrepDir -ItemType "directory" -Force > $null; log "Created SystemPrep directory -- ${SystemPrepDir}" } else { log "SystemPrep directory already exists -- $SystemPrepDir" }
$ScriptFileName = (${SystemPrepMasterScriptUrl}.split('/'))[-1]
$ScriptFullPath = "${SystemPrepDir}\${ScriptFileName}"
log "Downloading the SystemPrep master script -- ${SystemPrepMasterScriptUrl}"
Download-File $SystemPrepMasterScriptUrl $ScriptFullPath -SourceIsS3Bucket:$SourceIsS3Bucket | log
log "Running the SystemPrep master script -- ${ScriptFullPath}"
(Invoke-Expression "& ${ScriptFullPath} @SystemPrepParams" 2>&1) | log
log "Exiting SystemPrep BootStrap script"
