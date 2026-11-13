# start-superagent.ps1 — Levanta dsh-superagent en modo local y abre el panel en el navegador.
# Uso:  .\start-superagent.ps1            inicia (si ya esta corriendo, solo abre el panel)
#       .\start-superagent.ps1 -Stop      detiene el servicio
$ErrorActionPreference = 'Stop'
$ProfileName = 'superagent-local'
$Port        = 3083
$Root        = $PSScriptRoot
$StateDir    = Join-Path $env:DSH_HOME "$env:USERPROFILE\.dsh\state\$ProfileName"
if ($env:DSH_HOME) { $StateDir = Join-Path $env:DSH_HOME "state\$ProfileName" } else { $StateDir = Join-Path "$env:USERPROFILE\.dsh" "state\$ProfileName" }
$LogFile     = Join-Path $Root ".artifacts\superagent-local.log"
$PidFile     = Join-Path $Root ".artifacts\superagent-local.pid"

function Test-Running {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return $conn
}

function Open-Panel {
    # El servidor exige token; lo leemos del log mas reciente si hace falta.
    $url = "http://127.0.0.1:$Port/"
    if (Test-Path $LogFile) {
        $tokenLine = Select-String -Path $LogFile -Pattern 'dsh web: (\S+)' | Select-Object -Last 1
        if ($tokenLine) { $url = $tokenLine.Matches[0].Groups[1].Value }
    }
    Write-Host "Abriendo panel: $url" -ForegroundColor Green
    Start-Process $url
}

if ($args -contains '-Stop') {
    # Matar por linea de comando: procesos cuyo command line mencione el perfil o sea un runner
    # huesped de dsh-subprocess-local lanzado desde este checkout. Excluir el propio powershell del script.
    $selfPid = $PID
    $targets = Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $selfPid -and
        $_.CommandLine -match 'superagent-local|dsh-subprocess-local' -and
        $_.Name -notin @('powershell.exe','pwsh.exe')
    } | Select-Object ProcessId, Name
    if (-not $targets) {
        Write-Host "No hay procesos del servicio corriendo."
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        exit 0
    }
    Write-Host ("Deteniendo " + @($targets).Count + " proceso(s)...")
    foreach ($t in $targets) {
        taskkill /F /T /PID $t.ProcessId 2>&1 | Out-Null
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $still = Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $selfPid -and $_.CommandLine -match 'superagent-local|dsh-subprocess-local' -and $_.Name -notin @('powershell.exe','pwsh.exe')
    }
    if ($still) {
        Write-Host "Quedan procesos; reintentando..." -ForegroundColor Yellow
        foreach ($s in $still) { taskkill /F /T /PID $s.ProcessId 2>&1 | Out-Null }
    }
    Write-Host "Detenido." -ForegroundColor Yellow
    exit 0
}

New-Item -ItemType Directory -Path (Join-Path $Root '.artifacts') -Force | Out-Null

if (Test-Running) {
    Write-Host "superagent-local ya esta corriendo en el puerto $Port." -ForegroundColor Cyan
    Open-Panel
    exit 0
}

Write-Host "Iniciando superagent-local (perfil $ProfileName, puerto $Port)..."
$env:DSH_HOME = Join-Path "$env:USERPROFILE" '.dsh'

# Lanzar dsh en una consola propia y desvinculada del powershell (sobrevive al cerrar terminales).
# La ventana aparece MINIMIZADA; no se puede cerrar por accidente porque esta fuera de vista.
$errLog   = Join-Path $Root ".artifacts\superagent-local.err.log"
$inner    = "cd /d `"$Root`" && dsh --profile $ProfileName --no-open >> `"$LogFile`" 2>> `"$errLog`""
$proc     = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'start', '/MIN', '"superagent-local"', 'cmd', '/c', $inner) -PassThru
Set-Content -Path $PidFile -Value $proc.Id

# Esperar a que levante y capture el token mas reciente del log (descartando los anteriores).
$before = if (Test-Path $LogFile) { @((Get-Content $LogFile | Select-String 'dsh web: ').Count) } else { 0 }
$deadline = (Get-Date).AddSeconds(90)
$url = $null
while ((Get-Date) -lt $deadline) {
    if (Test-Path $LogFile) {
        $hits = @(Get-Content $LogFile | Select-String 'dsh web: (\S+)')
        if ($hits.Count -gt $before) { $url = $hits[-1].Matches[0].Groups[1].Value; break }
    }
    # Fallback: si el puerto ya escucha, el servicio esta arriba aunque el log este retrasado.
    if (-not $url -and (Test-Running)) {
        $conn = Test-Running
        Write-Host "Servicio escuchando en el puerto $Port (PID $($conn.OwningProcess))." -ForegroundColor Green
    }
    Start-Sleep -Milliseconds 500
}

if ($url) {
    Write-Host "Servicio listo." -ForegroundColor Green
    Write-Host "Panel: $url" -ForegroundColor Cyan
    Start-Process $url
} else {
    Write-Host "Servicio lanzado pero no capture el token a tiempo." -ForegroundColor Yellow
    Write-Host "Revisa el log: $LogFile"
    Write-Host "Abre manualmente http://127.0.0.1:$Port/ cuando aparezca el token."
}
