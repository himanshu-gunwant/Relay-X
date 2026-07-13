$ErrorActionPreference = "Stop"

$nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodePath) {
    Write-Host "Node.js not found in PATH. Using default fallback."
    $nodePath = "C:\Program Files\nodejs\node.exe"
}

$projectDir = "d:\Antigravity Companion\relay-server"
$scriptPath = "$projectDir\dist\index.js"

# We run it via cmd.exe so we can redirect output to a log file
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$nodePath`" `"$scriptPath`" >> `"$projectDir\service.log`" 2>&1" -WorkingDirectory $projectDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger

Write-Host "Registering Scheduled Task 'AntigravityRelayServer' to run at SYSTEM startup..."
Register-ScheduledTask -TaskName "AntigravityRelayServer" -InputObject $task -Force

Write-Host "Starting the service now..."
Start-ScheduledTask -TaskName "AntigravityRelayServer"

Write-Host "Service installed and started successfully! Press any key to exit."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
