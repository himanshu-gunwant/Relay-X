$ErrorActionPreference = "Stop"

$projectDir = "d:\Antigravity Companion\relay-server"
$batPath = "$projectDir\start_service.bat"

$action = New-ScheduledTaskAction -Execute $batPath -WorkingDirectory $projectDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

$task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings

Write-Host "Registering Scheduled Task 'AntigravityRelayServer' to run at SYSTEM startup..."
Register-ScheduledTask -TaskName "AntigravityRelayServer" -InputObject $task -Force

Write-Host "Starting the service now..."
Start-ScheduledTask -TaskName "AntigravityRelayServer"

Write-Host "Service installed and started successfully! Press any key to exit."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
