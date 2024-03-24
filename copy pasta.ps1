#This script is used to get the agent deployment script from within the #limited ScreenConnect command window YOU MUST COPY/PASTE EVERYTHING BELOW INTO THE WINDOW AND SET THE ENROLLMENT TOKEN


powershell Set-ExecutionPolicy -ExecutionPolicy Unrestricted
powershell Invoke-WebRequest -Uri https://raw.githubusercontent.com/jamsub/sunder/main/agent_deploy.ps1 -OutFile agent_deploy.ps1
timeout /t 20 
powershell .\agent_deploy.ps1 -enrollmentToken "CHANGE ME"
