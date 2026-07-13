$ErrorActionPreference = "Stop"

# Get current username
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Define task parameters
$taskName = "AntigravityAutoLock"

# We run via PowerShell with a hidden window and a 3-second delay to allow the Windows session to initialize first.
# Otherwise, running LockWorkStation immediately during the logon sequence can fail silently.
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NoProfile -Command `"Start-Sleep -Seconds 3; rundll32.exe user32.dll,LockWorkStation`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

# Settings: Ensure it runs as fast as possible on login and doesn't get blocked by power status
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings

Write-Host "Updating Auto-Lock Scheduled Task '$taskName' for user $currentUser with a 3-second delay..."
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force

Write-Host "Auto-Lock task updated successfully! Windows will now wait 3 seconds after logon to ensure the desktop session is ready before locking."
Write-Host "Press any key to exit."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
