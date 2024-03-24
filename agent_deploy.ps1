# PowerShell script to deploy SUNDER SIEM Agent

param (
    [string]$enrollmentToken
)
mkdir C:\sunder
cd C:\sunder

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.12.2-windows-x86_64.zip -OutFile elastic-agent-8.12.2-windows-x86_64.zip

Expand-Archive .\elastic-agent-8.12.2-windows-x86_64.zip -DestinationPath .
cd elastic-agent-8.12.2-windows-x86_64

.\elastic-agent.exe install -n --url=https://865728532f2e49c5bfd2f987753d5c01.fleet.us-central1.gcp.cloud.es.io:443 --enrollmentToken=$enrollmentToken
