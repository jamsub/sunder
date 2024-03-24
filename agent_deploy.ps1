# PowerShell script to deploy Elastic Agent 
# YOU MUST CHANGE THE ENROLLMENT-TOKEN PER CUSTOMER
mkdir C:\elastic-agent
cd C:\elastic-agent

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.12.2-windows-x86_64.zip -OutFile elastic-agent-8.12.2-windows-x86_64.zip

Expand-Archive .\elastic-agent-8.12.2-windows-x86_64.zip -DestinationPath .
cd elastic-agent-8.12.2-windows-x86_64

.\elastic-agent.exe install -n --url=https://865728532f2e49c5bfd2f987753d5c01.fleet.us-central1.gcp.cloud.es.io:443 --enrollment-token=X3ZhamNJNEJkUTB0Q3RlVlc4Rno6ZVk0UXdaMTFSN2U1dTYyVHo0c3FIUQ== 