param([string]$command)

$omenMonPath = $env:OMENMON_PATH
if (-not $omenMonPath) { $omenMonPath = 'C:\Users\Himanshu\OmenMon\OmenMon.exe' }

if (-not (Test-Path $omenMonPath)) {
    Write-Error "OmenMon executable not found at $omenMonPath"
    exit 1
}

$tempOut = [System.IO.Path]::GetTempFileName()
$tempErr = [System.IO.Path]::GetTempFileName()

try {
    $batFile = [System.IO.Path]::GetTempFileName() + ".bat"
    $q = [char]34
    $batContent = "$q$omenMonPath$q $command > $q$tempOut$q 2> $q$tempErr$q"
    Set-Content -Path $batFile -Value $batContent
    
    Start-Process -FilePath $batFile -WindowStyle Hidden -Wait

    $outContent = Get-Content $tempOut -Raw -ErrorAction SilentlyContinue
    $errContent = Get-Content $tempErr -Raw -ErrorAction SilentlyContinue

    if ($outContent) { Write-Output $outContent }
    if ($errContent) { Write-Error $errContent }
} finally {
    Remove-Item $tempOut -ErrorAction SilentlyContinue
    Remove-Item $tempErr -ErrorAction SilentlyContinue
    Remove-Item $batFile -ErrorAction SilentlyContinue
}
