$ErrorActionPreference = "Stop"

$nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodePath) {
    Write-Host "Node.js not found in PATH. Using default fallback."
    $nodePath = "C:\Program Files\nodejs\node.exe"
}

$projectDir = Join-Path $PSScriptRoot "relay-server"
$scriptPath = "$projectDir\dist\index.js"

# We run it via cmd.exe so we can redirect output to a log file
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$nodePath`" `"$scriptPath`" >> `"$projectDir\service.log`" 2>&1" -WorkingDirectory $projectDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger

# Clean up legacy task if present
if (Get-ScheduledTask -TaskName "AntigravityRelayServer" -ErrorAction SilentlyContinue) {
    Write-Host "Removing legacy scheduled task 'AntigravityRelayServer'..."
    Unregister-ScheduledTask -TaskName "AntigravityRelayServer" -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host "Registering Scheduled Task 'RelayXServer' to run at SYSTEM startup..."
Register-ScheduledTask -TaskName "RelayXServer" -InputObject $task -Force

Write-Host "Starting the Relay-X service now..."
Start-ScheduledTask -TaskName "RelayXServer"

Write-Host "Relay-X service installed and started successfully! Press any key to exit."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
