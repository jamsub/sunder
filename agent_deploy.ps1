# PowerShell script to deploy SUNDER SIEM Agent
param (
    [Parameter(Mandatory=$true)]
    [string]$enrollmentToken
)
# Define the directory where you want to install Elastic Agent
$installDirectory = "C:\SUNDERAgent"
# Check if the installation directory already exists
if (!(Test-Path -Path $installDirectory -PathType Container)) {
    # If not exists, create the directory
    New-Item -ItemType Directory -Path $installDirectory
}
mkdir $installDirectory
cd $installDirectory
$ProgressPreference = 'SilentlyContinue'

# Define download URL for Elastic Agent
$downloadUrl = "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.12.2-windows-x86_64.zip"

$zipFilePath = "$installDirectory\elastic-agent-8.12.2-windows-x86_64.zip"

# Define your Elastic Stack URL
$elasticStackURL = "https://865728532f2e49c5bfd2f987753d5c01.fleet.us-central1.gcp.cloud.es.io:443"

# Check if the zip file already exists
if (!(Test-Path -Path $zipFilePath)) {
    # If not exists, download the Elastic Agent zip file
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFilePath
}

# Check if the zip file exists before proceeding
if (Test-Path -Path $zipFilePath) {
    # Expand the downloaded zip file
    Expand-Archive -Path $zipFilePath -DestinationPath $installDirectory

    # Change directory to the Elastic Agent directory
    Set-Location -Path "$installDirectory\elastic-agent-8.12.2-windows-x86_64"

    # Install the Elastic Agent
    .\elastic-agent.exe install -n --url=$elasticStackURL --enrollment-token=$enrollmentToken
} else {
    Write-Host "Failed to download Elastic Agent zip file."
}
