# PowerShell script to deploy SUNDER SIEM Agent
param (
    [Parameter(Mandatory=$true)]
    [string]$enrollmentToken
)
mkdir $installDirectory
cd $installDirectory
$ProgressPreference = 'SilentlyContinue'

# Define download URL for Elastic Agent
$downloadUrl = "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.12.2-windows-x86_64.zip"

# Define the directory where you want to install Elastic Agent
$installDirectory = "C:\SUNDERAgent"

# Define your Elastic Stack URL
$elasticStackURL = "https://865728532f2e49c5bfd2f987753d5c01.fleet.us-central1.gcp.cloud.es.io:443"

# Download the Elastic Agent zip file
Invoke-WebRequest -Uri $downloadUrl -OutFile "$installDirectory\elastic-agent-8.12.2-windows-x86_64.zip"

# Expand the downloaded zip file
Expand-Archive -Path "$installDirectory\elastic-agent-8.12.2-windows-x86_64.zip" -DestinationPath $installDirectory

# Change directory to the Elastic Agent directory
Set-Location -Path "$installDirectory\elastic-agent-8.12.2-windows-x86_64"

# Install the Elastic Agent
.\elastic-agent.exe install --url=$elasticStackURL --enrollment-token=$enrollmentToken
