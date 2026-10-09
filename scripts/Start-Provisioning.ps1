# Orquestrador da automação pós-instalação.
#
# Primeira execução: iniciado pelo First-Logon.ps1 embutido no autounattend.xml, a partir do pendrive.
#   - copia os scripts para C:\ProgramData\WorkstationProvisioning\scripts;
#   - registra uma tarefa agendada que reabre este script (cópia local) a cada logon do técnico,
#     para o provisionamento continuar depois dos reboots do Windows Update.
# O progresso fica em C:\ProgramData\WorkstationProvisioning\state.json.
#
# Roda em uma janela visível para que o técnico acompanhe em qual etapa o provisionamento está.
# Cada etapa roda em um processo PowerShell separado.

param(
    # Não aguarda ENTER no final. Uso em testes automatizados.
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'

$rootDir         = 'C:\ProgramData\WorkstationProvisioning'
$logDir          = Join-Path $rootDir 'Logs'
$logFile         = Join-Path $logDir 'deployment.log'
$stateFile       = Join-Path $rootDir 'state.json'
$localScriptsDir = Join-Path $rootDir 'scripts'

$taskPath = '\WorkstationProvisioning\'
$taskName = 'Resume'

$totalSteps              = 3
$maxUpdateCycles         = 6
$restartCountdownSeconds = 60

# Ligado quando o computador vai reiniciar: a janela fecha sem pausa.
$isRestarting = $false

. (Join-Path $PSScriptRoot 'Test-InternetConnection.ps1')

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    $line  = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Show-Step {
    param(
        [Parameter(Mandatory)] [int] $Number,
        [Parameter(Mandatory)] [string] $Name
    )
    $title = "Etapa $Number de $totalSteps - $Name"
    $Host.UI.RawUI.WindowTitle = "Provisionamento | $title"

    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Log "==== $title ===="
}

function Show-NetworkHelp {
    param([Parameter(Mandatory)] [int] $IntervalSeconds)
    Write-Host ''
    Write-Host '  SEM CONEXÃO COM A INTERNET - o provisionamento está pausado.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Verifique:' -ForegroundColor Yellow
    Write-Host '    1. O cabo de rede está conectado?' -ForegroundColor Yellow
    Write-Host '    2. Se a rede exigir login, abra o navegador e faça o login.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  A verificação é repetida automaticamente a cada $IntervalSeconds segundos." -ForegroundColor Yellow
    Write-Host '  NÃO feche esta janela: o provisionamento continua sozinho quando a conexão for detectada.' -ForegroundColor Yellow
    Write-Host ''
}

function Wait-InternetConnection {
    # Aguarda indefinidamente: a próxima etapa só começa quando houver acesso à internet.
    param(
        [int] $IntervalSeconds = 15,
        [int] $LogRepeatMinutes = 5
    )

    $attempt     = 0
    $lastReason  = $null
    $lastLogTime = [datetime]::MinValue

    while ($true) {
        $attempt++
        $info = $null
        $isConnected = Test-InternetConnection -InformationVariable info
        $reason = ($info | Select-Object -Last 1).MessageData

        if ($isConnected) {
            Write-Progress -Activity 'Aguardando conexão com a internet' -Completed
            Write-Log "Conexão com a internet detectada: $reason."
            return
        }

        if ($attempt -eq 1) {
            Show-NetworkHelp -IntervalSeconds $IntervalSeconds
        }

        # Registra só quando o motivo muda ou a cada $LogRepeatMinutes, para não encher o log.
        $isReasonChanged = $reason -ne $lastReason
        $isLogDue = ((Get-Date) - $lastLogTime).TotalMinutes -ge $LogRepeatMinutes
        if ($isReasonChanged -or $isLogDue) {
            Write-Log "Sem conexão: $reason. Aguardando..." -Level WARN
            $lastReason  = $reason
            $lastLogTime = Get-Date
        }

        Write-Progress -Activity 'Aguardando conexão com a internet' `
            -Status "Tentativa $attempt - última verificação às $(Get-Date -Format 'HH:mm:ss'). Próxima em $IntervalSeconds s."
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Invoke-Stage {
    # Executa uma etapa em processo separado e retorna o exit code.
    # Exit code fora de $AllowedExitCodes interrompe o provisionamento.
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Script,
        [int[]] $AllowedExitCodes = @(0)
    )
    $path = Join-Path $localScriptsDir $Script
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Script da etapa '$Name' não encontrado: $path"
    }

    Write-Log "Iniciando etapa: $Name"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path | ForEach-Object { Write-Log "  $_" }
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Etapa '$Name' falhou com exit code $exitCode"
    }
    Write-Log "Etapa concluída: $Name (exit code $exitCode)"
    return $exitCode
}

function Enter-SingleInstance {
    # Impede duas janelas de provisionamento ao mesmo tempo (ex.: logoff e login sem reboot).
    $script:instanceMutex = New-Object System.Threading.Mutex($false, 'Global\WorkstationProvisioning')
    try {
        return $script:instanceMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # A instância anterior terminou sem liberar o mutex (ex.: janela fechada); esta assume.
        return $true
    }
}

function New-ProvisioningState {
    return [pscustomobject] @{
        Status             = 'Running'
        StartedAt          = (Get-Date).ToString('s')
        UpdatedAt          = (Get-Date).ToString('s')
        CompletedSteps     = @()
        WindowsUpdateCycle = 0
        LastResult         = ''
    }
}

function Get-ProvisioningState {
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return New-ProvisioningState
    }

    try {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "O arquivo de estado está ilegível: $stateFile. $($_.Exception.Message)"
    }

    foreach ($property in 'Status', 'StartedAt', 'CompletedSteps', 'WindowsUpdateCycle', 'LastResult') {
        if ($null -eq $state.PSObject.Properties[$property]) {
            throw "O arquivo de estado está incompleto (falta '$property'): $stateFile"
        }
    }
    $state.CompletedSteps = @($state.CompletedSteps)
    return $state
}

function Save-ProvisioningState {
    # Grava em arquivo temporário e substitui: um desligamento no meio não corrompe o estado.
    param([Parameter(Mandatory)] $State)
    $State.UpdatedAt = (Get-Date).ToString('s')
    $tempFile = "$stateFile.tmp"
    $State | ConvertTo-Json | Set-Content -LiteralPath $tempFile -Encoding UTF8
    Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
}

function Test-StepCompleted {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Name
    )
    return $State.CompletedSteps -contains $Name
}

function Complete-Step {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not (Test-StepCompleted -State $State -Name $Name)) {
        $State.CompletedSteps = @($State.CompletedSteps) + $Name
    }
    Save-ProvisioningState -State $State
}

function Copy-ProvisioningScript {
    # Copia os scripts para o disco: a retomada após reboot não depende do pendrive nem da letra da unidade.
    $sourceDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
    if ($sourceDir -eq $localScriptsDir) {
        return
    }
    New-Item -ItemType Directory -Force -Path $localScriptsDir | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $localScriptsDir -Recurse -Force
    Write-Log "Scripts copiados de $sourceDir para $localScriptsDir."
}

function Register-ResumeTask {
    # Reabre o provisionamento (cópia local) a cada logon da conta atual, para continuar após os reboots.
    $userId     = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $scriptPath = Join-Path $localScriptsDir 'Start-Provisioning.ps1'

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Tarefa agendada de retomada registrada: $taskPath$taskName ($userId)."
}

function Unregister-ResumeTask {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
        Write-Log 'Tarefa agendada de retomada removida.'
    }
}

function Restart-ForWindowsUpdate {
    Write-Log 'As atualizações exigem reiniciar o computador.' -Level WARN

    Write-Host ''
    Write-Host '  As atualizações exigem reiniciar o computador.' -ForegroundColor Yellow
    Write-Host "  O computador será reiniciado em $restartCountdownSeconds segundos." -ForegroundColor Yellow
    Write-Host "  Depois do reinício, faça login na conta $($env:USERNAME): o provisionamento continua sozinho." -ForegroundColor Yellow
    Write-Host ''

    for ($remaining = $restartCountdownSeconds; $remaining -gt 0; $remaining--) {
        Write-Progress -Activity 'Reiniciando o computador' -Status "Reinício em $remaining s" -SecondsRemaining $remaining
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Reiniciando o computador' -Completed

    Write-Log 'Reiniciando o computador.'
    $script:isRestarting = $true
    Restart-Computer -Force
}

function Invoke-WindowsUpdateStep {
    # Repete os ciclos do Install-WindowsUpdates até não haver atualizações ou atingir $maxUpdateCycles.
    # O número do ciclo fica no state.json e sobrevive aos reboots.
    param([Parameter(Mandatory)] $State)

    while ($true) {
        $cycle = [int] $State.WindowsUpdateCycle + 1
        if ($cycle -gt $maxUpdateCycles) {
            Write-Log "Limite de $maxUpdateCycles ciclos atingido. Ainda pode haver atualizações pendentes; detalhes no windows-update.log." -Level WARN
            return
        }

        $State.WindowsUpdateCycle = $cycle
        Save-ProvisioningState -State $State

        Show-Step -Number 3 -Name "Windows Update (ciclo $cycle de $maxUpdateCycles)"
        $exitCode = Invoke-Stage -Name 'Install-WindowsUpdates' -Script 'Install-WindowsUpdates.ps1' -AllowedExitCodes 0, 2, 3010

        switch ($exitCode) {
            0 {
                $State.LastResult = 'NoUpdates'
                Save-ProvisioningState -State $State
                Write-Log 'Nenhuma atualização pendente. Windows Update concluído.'
                return
            }
            2 {
                $State.LastResult = 'Installed'
                Save-ProvisioningState -State $State
                Write-Log 'Atualizações processadas sem necessidade de reiniciar. Procurando novamente.'
            }
            3010 {
                $State.LastResult = 'RebootRequired'
                Save-ProvisioningState -State $State
                Restart-ForWindowsUpdate
                return
            }
        }
    }
}

function Start-Provisioning {
    $isFirstRun = -not (Test-Path -LiteralPath $stateFile)
    $state = Get-ProvisioningState

    if ($state.Status -eq 'Completed') {
        Write-Log "O provisionamento já foi concluído em $($state.UpdatedAt). Nada a fazer."
        Unregister-ResumeTask
        return
    }

    if ($isFirstRun) {
        Write-Log '==== Início do provisionamento ===='
    }
    else {
        Write-Log ("==== Retomando o provisionamento (etapas concluídas: {0}; ciclos de Windows Update: {1}) ====" -f `
            $(if ($state.CompletedSteps.Count -gt 0) { $state.CompletedSteps -join ', ' } else { 'nenhuma' }), $state.WindowsUpdateCycle)
    }
    Save-ProvisioningState -State $state
    Copy-ProvisioningScript
    Register-ResumeTask

    Show-Step -Number 1 -Name 'Primeiro logon'
    if (Test-StepCompleted -State $state -Name 'First-Logon') {
        Write-Log 'Etapa já concluída anteriormente.'
    }
    else {
        $null = Invoke-Stage -Name 'First-Logon' -Script 'First-Logon.ps1'
        Complete-Step -State $state -Name 'First-Logon'
    }

    # A verificação de rede não é marcada como concluída: roda a cada retomada,
    # porque a conexão pode ter caído durante o reboot.
    Show-Step -Number 2 -Name 'Verificação de conexão com a internet'
    Wait-InternetConnection

    if (Test-StepCompleted -State $state -Name 'Install-WindowsUpdates') {
        Show-Step -Number 3 -Name 'Windows Update'
        Write-Log 'Etapa já concluída anteriormente.'
    }
    else {
        Invoke-WindowsUpdateStep -State $state
        if ($script:isRestarting) {
            return
        }
        Complete-Step -State $state -Name 'Install-WindowsUpdates'
    }

    $state.Status = 'Completed'
    Save-ProvisioningState -State $state
    Unregister-ResumeTask
    Write-Log '==== Provisionamento concluído ===='
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (-not (Enter-SingleInstance)) {
    Write-Host ''
    Write-Host '  O provisionamento já está em execução em outra janela.' -ForegroundColor Yellow
    Write-Host '  Esta janela será fechada em 10 segundos.' -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    exit 0
}

$exitCode = 0
try {
    Start-Provisioning
    if (-not $isRestarting) {
        $Host.UI.RawUI.WindowTitle = 'Provisionamento | Concluído'
        Write-Host ''
        Write-Host ('=' * 64) -ForegroundColor Green
        Write-Host '  PROVISIONAMENTO CONCLUÍDO.' -ForegroundColor Green
        Write-Host '  As próximas etapas (domínio, aplicativos) ainda não foram implementadas.' -ForegroundColor Green
        Write-Host "  Log: $logFile" -ForegroundColor Green
        Write-Host ('=' * 64) -ForegroundColor Green
    }
}
catch {
    $exitCode = 1
    Write-Log $_.Exception.Message -Level ERROR
    $Host.UI.RawUI.WindowTitle = 'Provisionamento | ERRO'
    Write-Host ''
    Write-Host '  PROVISIONAMENTO INTERROMPIDO POR ERRO.' -ForegroundColor Red
    Write-Host "  Detalhes no log: $logFile" -ForegroundColor Red
    Write-Host '  Para tentar de novo, faça logoff e login: a janela é reaberta automaticamente.' -ForegroundColor Red
}

# O computador vai reiniciar: fecha sem pausa.
if ($isRestarting) {
    exit 0
}

if (-not $NoPause) {
    Write-Host ''
    Read-Host '  Pressione ENTER para fechar esta janela' | Out-Null
}
exit $exitCode
