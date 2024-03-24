#This script is used to get the agent deployment script from within the #limited ScreenConnect command window YOU MUST COPY/PASTE EVERYTHING BELOW INTO THE WINDOW AND SET THE ENROLLMENT TOKEN
#Here is the link to the tokens https://182683e7a48b41bdba7286d5ac2488e7.us-central1.gcp.cloud.es.io:9243/app/fleet/enrollment-tokens

powershell Set-ExecutionPolicy -ExecutionPolicy Unrestricted
powershell Invoke-WebRequest -Uri https://raw.githubusercontent.com/jamsub/sunder/main/agent_deploy.ps1 -OutFile agent_deploy.ps1
timeout /t 20 
powershell .\agent_deploy.ps1 -enrollmentToken "CHANGE ME"
