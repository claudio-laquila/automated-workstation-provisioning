# Orquestrador da automação pós-instalação.
# Iniciado pelo First-Logon.ps1 embutido no autounattend.xml, em uma janela própria e visível,
# para que o técnico acompanhe em qual etapa o provisionamento está.
# Cada etapa roda em um processo PowerShell separado; exit code diferente de 0 interrompe o fluxo.

param(
    # Não aguarda ENTER no final. Uso em testes automatizados.
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'

$logDir     = 'C:\ProgramData\WorkstationProvisioning\Logs'
$logFile    = Join-Path $logDir 'deployment.log'
$totalSteps = 3

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
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Script
    )
    $path = Join-Path $PSScriptRoot $Script
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Script da etapa '$Name' não encontrado: $path"
    }

    Write-Log "Iniciando etapa: $Name"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path | ForEach-Object { Write-Log "  $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "Etapa '$Name' falhou com exit code $LASTEXITCODE"
    }
    Write-Log "Etapa concluída: $Name"
}

function Init {
    Write-Log '==== Início do provisionamento ===='

    Show-Step -Number 1 -Name 'Primeiro logon'
    Invoke-Stage -Name 'First-Logon' -Script 'First-Logon.ps1'

    Show-Step -Number 2 -Name 'Verificação de conexão com a internet'
    Wait-InternetConnection

    Show-Step -Number 3 -Name 'Windows Update'
    Invoke-Stage -Name 'Install-WindowsUpdates' -Script 'Install-WindowsUpdates.ps1'

    Write-Log '==== Provisionamento concluído ===='
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$exitCode = 0
try {
    Init
    $Host.UI.RawUI.WindowTitle = 'Provisionamento | Concluído'
    Write-Host ''
    Write-Host '  PROVISIONAMENTO CONCLUÍDO.' -ForegroundColor Green
}
catch {
    $exitCode = 1
    Write-Log $_.Exception.Message -Level ERROR
    $Host.UI.RawUI.WindowTitle = 'Provisionamento | ERRO'
    Write-Host ''
    Write-Host '  PROVISIONAMENTO INTERROMPIDO POR ERRO.' -ForegroundColor Red
    Write-Host "  Detalhes no log: $logFile" -ForegroundColor Red
}

if (-not $NoPause) {
    Write-Host ''
    Read-Host '  Pressione ENTER para fechar esta janela' | Out-Null
}
exit $exitCode
