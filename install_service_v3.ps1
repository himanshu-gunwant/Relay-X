$ErrorActionPreference = "Stop"

$projectDir = Join-Path $PSScriptRoot "relay-server"
$batPath = "$projectDir\start_service.bat"

$action = New-ScheduledTaskAction -Execute $batPath -WorkingDirectory $projectDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

$task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings

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
