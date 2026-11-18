$ErrorActionPreference = "Stop"

# Get current username
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Define task parameters
$taskName = "RelayXAutoLock"
$legacyTask = "AntigravityAutoLock"
if (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $legacyTask -Confirm:$false -ErrorAction SilentlyContinue
}
$action = New-ScheduledTaskAction -Execute "rundll32.exe" -Argument "user32.dll,LockWorkStation"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

# Settings: Ensure it runs as fast as possible on login and doesn't get blocked by power status
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings

Write-Host "Registering Auto-Lock Scheduled Task '$taskName' for user $currentUser..."
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force

Write-Host "Auto-Lock task registered successfully! Your PC will now automatically lock as soon as you log in."
Write-Host "Press any key to exit."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
