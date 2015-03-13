<powershell>
#User variables
$SystemPrepMasterScriptUrl = 'https://s3.amazonaws.com/systemprep/MasterScripts/SystemPrep-WindowsMaster.ps1'
$SystemPrepParams = @{
    AshRole = "Workstation"
    NetBannerLabel = "Unclass"
    SaltStates = "Highstate"
    NoReboot = $false
    SourceIsS3Bucket = $true
    AwsRegion = "us-east-1"
}
$AwsToolsUrl = $null
$RootCertUrl = $null

#System variables
$DateTime = $(get-date -format "yyyyMMdd_HHmm_ss")
$ScriptName = $MyInvocation.mycommand.name
$SystemPrepDir = "${env:SystemDrive}\SystemPrep"
$SystemPrepLogFile = "${SystemPrepDir}\SystemPrep-Log_${DateTime}.txt"
$CertDir = "${env:temp}\certs"

function log {
	[CmdLetBinding()]
	Param(
		[Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] $LogMessage
	)
	PROCESS {
		foreach ($message in $LogMessage) {
			#Writes the input $LogMessage to the log file $SystemPrepLogFile.
			Add-Content -Path $SystemPrepLogFile -Value "$(get-date -format `"yyyyMMdd_HHmm_ss`"): ${ScriptName}: ${message}"
		}
	}
}

function Download-File {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] $Url,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $SavePath,
        [Parameter(Mandatory=$false,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [switch] $SourceIsS3Bucket,
        [Parameter(Mandatory=$false,Position=3,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $AwsRegion
    )
	BEGIN {
		New-Item -Path ${SavePath} -ItemType Directory -Force -WarningAction SilentlyContinue > $null
	}
    PROCESS {
		foreach ($url_item in $Url) {
			$FileName = "${SavePath}\$((${url_item}.split('/'))[-1])"
			if ($SourceIsS3Bucket) {
				Write-Verbose "Downloading file from S3 bucket: ${url_item}"
				$SplitUrl = $url_item.split('/') | where { $_ -notlike "" }
				$BucketName = $SplitUrl[2]
				$Key = $SplitUrl[3..($SplitUrl.count-1)] -join '/'
				$ret = Invoke-Expression "Powershell Read-S3Object -BucketName $BucketName -Key $Key -File $FileName -Region $AwsRegion"
			}
			else {
				Write-Verbose "Downloading file from HTTP host: ${url_item}"
				(new-object net.webclient).DownloadFile("${url_item}","${FileName}")
			}
			Write-Output (Get-Item $FileName)
		}
    }
}

function Expand-ZipFile {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] $FileName,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $DestPath,
        [Parameter(Mandatory=$false,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [switch] $CreateDirFromFileName
    )
    PROCESS {
		foreach ($file in $FileName) {
			$Shell = new-object -com shell.application
			if (!(Test-Path "$file")) {
				throw "$file does not exist" 
			}
			Write-Verbose "Unzipping file: ${file}"
			if ($CreateDirFromFileName) { $DestPath = "${DestPath}\$((Get-Item $file).BaseName)" }
			New-Item -Path $DestPath -ItemType Directory -Force -WarningAction SilentlyContinue > $null
			$Shell.namespace($DestPath).copyhere($Shell.namespace("$file").items(), 0x14) 
			Write-Output (Get-Item $DestPath)
		}
	}
}

function Import-509Certificate {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$false)] [string[]] $certPath,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $certRootStore,
        [Parameter(Mandatory=$true,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $certStore
    )
    PROCESS {
		foreach ($item in $certpath) {
			Write-Verbose "Importing certificate: ${item}"
			$pfx = new-object System.Security.Cryptography.X509Certificates.X509Certificate2
			$pfx.import($item)

			$store = new-object System.Security.Cryptography.X509Certificates.x509Store($certStore,$certRootStore)
			$store.open("MaxAllowed")
			$store.add($pfx)
			$store.close()
		}
    }
}

function Install-RootCerts {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$false)] [string[]] $RootCertHost
	)
	PROCESS {
		foreach ($item in $RootCertHost) {
			$CertDir = "${env:temp}\certs-$(${item}.Replace(`"http://`",`"`"))"
			New-Item -Path $CertDir -ItemType "directory" -Force -WarningAction SilentlyContinue > $null
			Write-Verbose "...Checking for certificates hosted by: $item..."
			$CertUrls = @((Invoke-WebRequest -Uri $item).Links | where { $_.href -match ".*\.cer$"} | foreach-object {$item + $_.href})
			Write-Verbose "...Found $(${CertUrls}.count) certificate(s)..."
			Write-Verbose "...Downloading certificate(s)..."
			$CertFiles = $CertUrls | Download-File -SavePath $CertDir
            $TrustedRootCACertFiles = $CertFiles | where { $_.Name -match ".*root.*" }
            $IntermediateCACertFiles = $CertFiles | where { $_.Name -notmatch ".*root.*" }
			Write-Verbose "...Beginning import of $(${TrustedRootCACertFiles}.count) trusted root CA certificate(s)..."
			$TrustedRootCACertFiles | Import-509Certificate -certRootStore "LocalMachine" -certStore "Root"
			Write-Verbose "...Beginning import of $(${IntermediateCACertFiles}.count) intermediate CA certificate(s)..."
			$IntermediateCACertFiles | Import-509Certificate -certRootStore "LocalMachine" -certStore "CA"
			Write-Verbose "...Completed import of certificate(s) from: ${item}"
		}
	}
}

Function Install-AwsSdkEndpointXml {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$false)] [string[]] $AwsToolsUrl
	)
	PROCESS {
		foreach ($item in $AwsToolsUrl) {
			Write-Verbose "...Beginning import of AWS SDK Endpoints XML file..."
			$AwsToolsFile = Download-File -Url $item -SavePath ${env:temp}
			Write-Verbose "...Extracting AWS Tools..."
			$AwsToolsDir = Expand-ZipFile -FileName $AwsToolsFile -DestPath ${env:temp} -CreateDirFromFileName
			$AwsSdkEndpointSource = "${AwsToolsDir}\customization\sdk\AWSSDK.endpoints.xml"
			$AwsSdkEndpointDest = "${Env:ProgramFiles(x86)}\AWS Tools\PowerShell\AWSPowerShell"
			Write-Verbose "Copying AWS SDK Endpoints XML file -- "
			Write-Verbose "  -- source: ${AwsSdkEndpointSource}"
			Write-Verbose "  -- dest:   ${AwsSdkEndpointDest}"
			Copy-Item $AwsSdkEndpointSource $AwsSdkEndpointDest
			Write-Verbose "...Completed import of AWS SDK Endpoints XML file..."
		}
	}
}

New-Item -Path $SystemPrepDir -ItemType "directory" -Force > $null
log "Created the SystemPrep Working Directory: ${SystemPrepDir}"

if ($RootCertUrl) {
	Install-RootCerts -RootCertHost $RootCertUrl -Verbose *>&1 | log
}

if ($AwsToolsUrl) {
	Install-AwsSdkEndpointXml -AwsToolsUrl $AwsToolsUrl -Verbose *>&1 | log
}

log "Downloading the SystemPrep master script: ${SystemPrepMasterScriptUrl}"
$SystemPrepMasterScript = Download-File $SystemPrepMasterScriptUrl $SystemPrepDir -SourceIsS3Bucket:($SystemPrepParams["SourceIsS3Bucket"]) -AwsRegion $SystemPrepParams["AwsRegion"]
log "Running the SystemPrep master script: ${SystemPrepMasterScript}"
Invoke-Expression "& ${SystemPrepMasterScript} @SystemPrepParams" *>&1 | log
log "Exiting SystemPrep BootStrap script"
</powershell>