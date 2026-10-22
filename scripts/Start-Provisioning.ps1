# Orquestrador da automação pós-instalação.
#
# Primeira execução: iniciado pelo First-Logon.ps1 embutido no autounattend.xml, a partir do pendrive.
#   - copia os scripts, os arquivos de config\ (apps.json, domain.json, corporate-apps.json, office-odt.xml)
#     e os instaladores de reserva (installers\) para C:\ProgramData\WorkstationProvisioning;
#   - registra uma tarefa agendada que reabre este script (cópia local) a cada logon do técnico,
#     para o provisionamento continuar depois dos reboots do Windows Update;
#   - guarda a senha do login automático (config\autologon.txt do pendrive) como segredo protegido do Windows:
#     antes de cada reboot, o Windows é configurado para entrar sozinho na conta, uma única vez (AutoLogon.ps1).
# O progresso fica em C:\ProgramData\WorkstationProvisioning\state.json.
#
# Roda em uma janela visível para que o técnico acompanhe em qual etapa o provisionamento está.
# Enquanto a janela estiver aberta, a máquina não suspende por inatividade e cliques não pausam o script.
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

$totalSteps              = 7
$maxUpdateCycles         = 6
$restartCountdownSeconds = 60

# Senha do login automático, em Base64, na pasta config\ do pendrive (ao lado de scripts\).
# Só é lida na primeira execução, a partir do pendrive. Não versionar (está no .gitignore).
$credentialFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\autologon.txt'

# Ligado quando o computador vai reiniciar: a janela fecha sem pausa.
$isRestarting = $false

# Domínio esperado (config\domain.json, copiado do pendrive). Sem senha: o ingresso é feito pelo técnico.
$domainConfigFile = Join-Path $rootDir 'config\domain.json'

# Ligado quando a senha do login automático está guardada nesta máquina.
$isAutoLogonAvailable = $false

# Quantos logins automáticos cada ativação permite. Renovado a cada execução e antes de cada reboot do
# orquestrador. Se a máquina for abandonada no meio, o login automático se esgota sozinho.
$autoLogonCount = 10

# Configuração original do reinício automático do Windows Update, restaurada ao concluir (AutoRestartPolicy.ps1).
$autoRestartBackupFile = Join-Path $rootDir 'auto-restart-policy-backup.json'

# Configuração original de hibernação e suspensão, restaurada ao concluir (PowerPolicy.ps1).
$powerBackupFile = Join-Path $rootDir 'power-policy-backup.json'

. (Join-Path $PSScriptRoot 'Test-InternetConnection.ps1')
. (Join-Path $PSScriptRoot 'AutoLogon.ps1')
. (Join-Path $PSScriptRoot 'AutoRestartPolicy.ps1')
. (Join-Path $PSScriptRoot 'PowerPolicy.ps1')
. (Join-Path $PSScriptRoot 'Install-CorporateSoftware.ps1')

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

function Test-RunningFromUsb {
    # Rodando a partir do pendrive (primeira execução)? Nas retomadas, roda da cópia local.
    $sourceDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
    return $sourceDir -ne $localScriptsDir
}

function Show-UsbRemovalNotice {
    # Avisa que o pendrive não é mais necessário: os arquivos já foram copiados para o disco (Copy-ProvisioningFile)
    # e a senha do login automático já foi guardada no Windows (etapa 1).
    $usbRoot = Split-Path -Parent (Resolve-Path -LiteralPath $PSScriptRoot).Path
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor Green
    Write-Host "  O PENDRIVE ($usbRoot) JÁ PODE SER RETIRADO." -ForegroundColor Green
    Write-Host "  Os arquivos do provisionamento já foram copiados para $rootDir." -ForegroundColor Green
    if ($isAutoLogonAvailable) {
        Write-Host '  A senha do login automático já está guardada no Windows.' -ForegroundColor Green
    }
    Write-Host '  Retirar agora também evita que um reinício abra o menu do pendrive em vez do Windows.' -ForegroundColor Green
    Write-Host ('-' * 64) -ForegroundColor Green
    Write-Log "Pendrive ($usbRoot) não é mais necessário: arquivos copiados para $rootDir."
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
    # A saída da etapa aparece na janela: falhas em vermelho, avisos em amarelo.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path | ForEach-Object {
        $level = if ($_ -match '\[FALHA\]|\bFALHA:|^\s*ERRO\b') { 'ERROR' }
                 elseif ($_ -match '^\s*AVISO\b') { 'WARN' }
                 else { 'INFO' }
        Write-Log "  $_" -Level $level
    }
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Etapa '$Name' falhou com exit code $exitCode"
    }
    Write-Log "Etapa concluída: $Name (exit code $exitCode)"
    return $exitCode
}

function Add-NativeMethod {
    # Funções do Windows usadas para manter a máquina acordada e configurar a janela do console.
    if (-not ('WorkstationProvisioning.NativeMethods' -as [type])) {
        Add-Type -Namespace 'WorkstationProvisioning' -Name 'NativeMethods' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    }
}

function Disable-SystemSleep {
    # Impede suspensão e hibernação por inatividade enquanto esta janela estiver aberta.
    # Não altera o plano de energia: o Windows volta ao normal sozinho quando o processo termina.
    # Não impede a suspensão ao fechar a tampa do notebook.
    $esContinuous     = [uint32] 2147483648   # ES_CONTINUOUS (0x80000000)
    $esSystemRequired = [uint32] 1            # ES_SYSTEM_REQUIRED (0x00000001)
    $previousState = [WorkstationProvisioning.NativeMethods]::SetThreadExecutionState($esContinuous -bor $esSystemRequired)
    if ($previousState -eq 0) {
        throw 'O Windows recusou o pedido para manter a máquina acordada (SetThreadExecutionState).'
    }
    Write-Log 'Suspensão e hibernação por inatividade bloqueadas enquanto o provisionamento estiver aberto.'
}

function Disable-ConsoleQuickEdit {
    # Desativa a seleção com o mouse (QuickEdit) somente nesta janela.
    # Com ela ativa, um clique seleciona texto e o Windows pausa o script até ESC ou ENTER.
    $stdInputHandle     = -10     # STD_INPUT_HANDLE
    $enableQuickEdit    = 0x0040  # ENABLE_QUICK_EDIT_MODE
    $enableExtendedFlag = 0x0080  # ENABLE_EXTENDED_FLAGS (necessário para alterar o QuickEdit)

    $handle = [WorkstationProvisioning.NativeMethods]::GetStdHandle($stdInputHandle)
    $mode = [uint32] 0
    if (-not [WorkstationProvisioning.NativeMethods]::GetConsoleMode($handle, [ref] $mode)) {
        throw 'Não foi possível ler o modo da janela do console (GetConsoleMode).'
    }
    $newMode = ($mode -band (-bnot [uint32] $enableQuickEdit)) -bor $enableExtendedFlag
    if (-not [WorkstationProvisioning.NativeMethods]::SetConsoleMode($handle, [uint32] $newMode)) {
        throw 'Não foi possível alterar o modo da janela do console (SetConsoleMode).'
    }
    Write-Log 'Seleção com o mouse desativada nesta janela (cliques não pausam mais o provisionamento).'
}

function Initialize-ProvisioningWindow {
    # Falhas aqui não interrompem o provisionamento, mas ficam registradas como aviso.
    try {
        Add-NativeMethod
    }
    catch {
        Write-Log "Não foi possível carregar as funções do Windows: $($_.Exception.Message). A máquina pode suspender e cliques podem pausar a janela." -Level WARN
        return
    }

    try {
        Disable-SystemSleep
    }
    catch {
        Write-Log "$($_.Exception.Message) A máquina pode suspender durante o provisionamento." -Level WARN
    }

    try {
        Disable-ConsoleQuickEdit
    }
    catch {
        Write-Log "$($_.Exception.Message) Cliques na janela podem pausar o provisionamento." -Level WARN
    }
}

function Show-UpdateHelp {
    Write-Host ''
    Write-Host '  NÃO desligue, NÃO reinicie e NÃO feche a tampa do notebook.' -ForegroundColor Yellow
    Write-Host '  O computador reinicia sozinho quando necessário, com aviso de 60 segundos.' -ForegroundColor Yellow
    Write-Host '  Atualizações grandes podem levar de 20 a 40 minutos sem mudar a tela: isso é normal.' -ForegroundColor Yellow
    Write-Host ''
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

function Copy-ProvisioningFile {
    # Copia do pendrive para o disco o que as etapas precisam depois dos reboots,
    # para não depender do pendrive nem da letra da unidade:
    #   scripts\               → todos os scripts;
    #   config\apps.json       → lista de aplicativos (o config\autologon.txt NÃO é copiado);
    #   installers\            → instaladores de reserva dos aplicativos, se existirem.
    $sourceDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
    if ($sourceDir -eq $localScriptsDir) {
        return
    }
    $sourceRoot = Split-Path -Parent $sourceDir

    New-Item -ItemType Directory -Force -Path $localScriptsDir | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $localScriptsDir -Recurse -Force
    Write-Log "Scripts copiados de $sourceDir para $localScriptsDir."

    # Arquivos de configuração (o config\autologon.txt, com a senha, NUNCA é copiado).
    $localConfigDir = Join-Path $RootDir 'config'
    New-Item -ItemType Directory -Force -Path $localConfigDir | Out-Null
    foreach ($configName in 'apps.json', 'domain.json', 'corporate-apps.json', 'office-odt.xml') {
        $configSource = Join-Path $sourceRoot "config\$configName"
        if (Test-Path -LiteralPath $configSource) {
            Copy-Item -LiteralPath $configSource -Destination $localConfigDir -Force
            Write-Log "Configuração copiada: $configSource."
        }
        else {
            Write-Log "Configuração não encontrada no pendrive: $configSource." -Level WARN
        }
    }

    $installers = Join-Path $sourceRoot 'installers'
    if (Test-Path -LiteralPath $installers) {
        $localInstallersDir = Join-Path $RootDir 'installers'
        New-Item -ItemType Directory -Force -Path $localInstallersDir | Out-Null
        Copy-Item -Path (Join-Path $installers '*') -Destination $localInstallersDir -Recurse -Force
        Write-Log "Instaladores de reserva copiados de $installers para $localInstallersDir."
    }
    else {
        Write-Log "Pasta de instaladores de reserva não encontrada no pendrive ($installers): só o download será usado." -Level WARN
    }
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

function Initialize-AutoLogon {
    # Prepara e ATIVA o login automático (decisões L1 a L4).
    # A ativação acontece a cada execução, valendo para até $autoLogonCount logins, para cobrir qualquer
    # reinício: o do orquestrador, o do próprio Windows Update ou um manual.
    # Falhas não interrompem o provisionamento: o técnico passa a fazer login manualmente.
    try {
        # Diagnóstico: como o login automático estava antes de ser renovado. AutoLogonCount menor que
        # $autoLogonCount indica que o último login foi automático.
        $previous = Get-AutoLogonState
        Write-Log ('Login automático encontrado ao iniciar: AutoAdminLogon={0}, DefaultDomainName={1}, DefaultUserName={2}, AutoLogonCount={3}.' -f `
            $previous.AutoAdminLogon, $previous.DefaultDomainName, $previous.DefaultUserName, $previous.AutoLogonCount)

        if (Remove-PlainTextAutoLogonPassword) {
            Write-Log 'Senha em texto puro encontrada e removida do registro (Winlogon\DefaultPassword).' -Level WARN
        }

        if (Test-AutoLogonCredential) {
            $script:isAutoLogonAvailable = $true
            Write-Log 'Login automático disponível (senha guardada como segredo protegido do Windows).'
        }
        elseif (-not (Test-Path -LiteralPath $credentialFile)) {
            Write-Log "Arquivo de login automático não encontrado: $credentialFile. Após cada reboot, faça login manualmente na conta $($env:USERNAME)." -Level WARN
            return
        }
        else {
            Import-AutoLogonCredential -Path $credentialFile -UserName $env:USERNAME
            $script:isAutoLogonAvailable = $true
            Write-Log "Senha do login automático lida de $credentialFile e guardada como segredo protegido do Windows."
        }

        Enable-AutoLogon -UserName $env:USERNAME -LogonCount $autoLogonCount
        Write-Log "Login automático ativado: em qualquer reinício, o Windows entra sozinho na conta $($env:USERNAME) (até $autoLogonCount vezes)."
    }
    catch {
        Write-Log "Login automático indisponível: $($_.Exception.Message) Após cada reboot, faça login manualmente na conta $($env:USERNAME)." -Level WARN
    }
}

function Initialize-RestartPolicy {
    # Impede o Windows Update de reiniciar a máquina sozinho enquanto o provisionamento roda.
    # Falha não interrompe o provisionamento, mas fica registrada.
    try {
        Disable-WindowsUpdateAutoRestart -BackupFile $autoRestartBackupFile
        Write-Log 'Reinício automático do Windows Update bloqueado durante o provisionamento (NoAutoRebootWithLoggedOnUsers = 1).'
    }
    catch {
        Write-Log "Não foi possível bloquear o reinício automático do Windows Update: $($_.Exception.Message) O Windows pode reiniciar a máquina sozinho." -Level WARN
    }
}

function Initialize-PowerPolicy {
    # Desliga hibernação e suspensão por inatividade enquanto o provisionamento roda (inclusive na tela de
    # login após um reboot). Falha não interrompe o provisionamento, mas fica registrada.
    try {
        Disable-ProvisioningPowerSaving -BackupFile $powerBackupFile
        Write-Log 'Plano de energia durante o provisionamento: suspender, hibernar e desligar a tela = nunca (tomada e bateria); hibernação desligada. Fechar a tampa ainda suspende.'
    }
    catch {
        Write-Log "Não foi possível desativar a hibernação/suspensão: $($_.Exception.Message) A máquina pode hibernar durante o provisionamento." -Level WARN
    }
}

function Restore-PowerPolicy {
    # Devolve a configuração original de hibernação e suspensão (fim do provisionamento).
    try {
        if (Restore-ProvisioningPowerPolicy -BackupFile $powerBackupFile) {
            Write-Log 'Configuração original de hibernação e suspensão restaurada.'
        }
    }
    catch {
        $message = 'Não foi possível restaurar a hibernação/suspensão: {0} Reverta manualmente: powercfg /hibernate on (e os tempos de suspensão desejados).' -f $_.Exception.Message
        Write-Log $message -Level ERROR
    }
}

function Restore-RestartPolicy {
    # Devolve a configuração original do reinício automático do Windows Update (fim do provisionamento).
    try {
        if (Restore-WindowsUpdateAutoRestart -BackupFile $autoRestartBackupFile) {
            Write-Log 'Configuração original do reinício automático do Windows Update restaurada.'
        }
    }
    catch {
        $message = ("Não foi possível restaurar o reinício automático do Windows Update: {0} Reverta manualmente: " +
            "Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoRebootWithLoggedOnUsers") -f $_.Exception.Message
        Write-Log $message -Level ERROR
    }
}

function Stop-AutoLogon {
    # Desliga o login automático. Com -RemoveCredential, apaga também a senha guardada (fim do provisionamento).
    param([switch] $RemoveCredential)
    try {
        Disable-AutoLogon -RemoveCredential:$RemoveCredential
        if ($RemoveCredential) {
            Write-Log 'Login automático desligado e senha guardada removida.'
        }
        else {
            Write-Log 'Login automático desligado.'
        }
    }
    catch {
        Write-Log "Não foi possível desligar o login automático: $($_.Exception.Message) Verifique manualmente (Winlogon\AutoAdminLogon)." -Level ERROR
    }
}

function Restart-ForWindowsUpdate {
    Write-Log 'As atualizações exigem reiniciar o computador.' -Level WARN

    $isAutoLogonEnabled = $false
    if ($isAutoLogonAvailable) {
        try {
            # Renova a contagem antes do reboot do orquestrador.
            Enable-AutoLogon -UserName $env:USERNAME -LogonCount $autoLogonCount
            $isAutoLogonEnabled = $true
            Write-Log "Login automático ativado para o próximo boot (conta $($env:USERNAME))."
        }
        catch {
            Write-Log "Não foi possível ativar o login automático: $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Host ''
    Write-Host '  As atualizações exigem reiniciar o computador.' -ForegroundColor Yellow
    Write-Host "  O computador será reiniciado em $restartCountdownSeconds segundos." -ForegroundColor Yellow
    if ($isAutoLogonEnabled) {
        Write-Host "  Depois do reinício, o Windows entra sozinho na conta $($env:USERNAME) e o provisionamento continua." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Depois do reinício, faça login na conta $($env:USERNAME): o provisionamento continua sozinho." -ForegroundColor Yellow
    }
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
        Show-UpdateHelp
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

function Get-DomainConfig {
    # Domínio esperado e padrão do nome do computador (config\domain.json).
    if (-not (Test-Path -LiteralPath $domainConfigFile)) {
        throw "Configuração do domínio não encontrada: $domainConfigFile"
    }
    try {
        $domainConfig = Get-Content -LiteralPath $domainConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Configuração do domínio inválida (JSON): $domainConfigFile. $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($domainConfig.domain)) {
        throw "Configuração do domínio sem o campo 'domain': $domainConfigFile"
    }
    return [pscustomobject] @{
        Domain      = $domainConfig.domain.Trim()
        NamePattern = [string] $domainConfig.computerNamePattern
        NameExample = [string] $domainConfig.computerNameExample
        TargetOu    = [string] $domainConfig.targetOu
        TargetOuName = [string] $domainConfig.targetOuName
    }
}

function Get-ComputerDistinguishedName {
    # Localização do computador no AD, gravada pelo Windows a cada processamento das políticas de grupo.
    # Não exige credencial. Atualizada pelo gpupdate depois que o computador é movido de OU.
    $state = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine' -ErrorAction SilentlyContinue
    if ($null -eq $state) {
        return ''
    }
    return [string] $state.'Distinguished-Name'
}

function Update-ComputerPolicy {
    # Atualiza as políticas do computador. "echo N" responde "não" se o gpupdate perguntar sobre reiniciar.
    Write-Log 'Atualizando as políticas de grupo do computador (gpupdate)...'
    $output = cmd.exe /c 'echo N | gpupdate /target:computer /force' 2>&1
    Write-Log ('gpupdate terminou com exit code {0}: {1}' -f $LASTEXITCODE, (($output | Where-Object { "$_".Trim() }) -join ' '))
}

function Test-ComputerInOu {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DistinguishedName,
        [Parameter(Mandatory)] [string] $TargetOu
    )
    # O computador está diretamente na OU: "CN=<nome>,<OU de destino>".
    return $DistinguishedName -match ('^CN=[^,]+,' + [regex]::Escape($TargetOu) + '$')
}

function Show-OuMoveHelp {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DistinguishedName
    )
    $current = if ($DistinguishedName) { $DistinguishedName } else { '(ainda não informada pelo Windows)' }
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Yellow
    Write-Host "  MOVA O COMPUTADOR $($env:COMPUTERNAME) PARA A OU `"$($Config.TargetOuName)`" NO AD." -ForegroundColor Yellow
    Write-Host ('=' * 64) -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Local atual: $current" -ForegroundColor Yellow
    Write-Host "  Destino:     $($Config.TargetOu)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Como mover:' -ForegroundColor Yellow
    Write-Host '    1. No DC01, abra "Usuários e Computadores do Active Directory".' -ForegroundColor Yellow
    Write-Host "    2. Localize o computador $($env:COMPUTERNAME) (normalmente na pasta Computers)." -ForegroundColor Yellow
    Write-Host "    3. Clique com o botão direito > Mover... > LAQUILA > $($Config.TargetOuName) > OK." -ForegroundColor Yellow
    Write-Host '    4. Volte a esta janela e pressione ENTER.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  O provisionamento atualiza as políticas e confere a mudança.' -ForegroundColor Yellow
    Write-Host ''
}

function Confirm-ComputerOu {
    # Etapa 6: o computador precisa estar na OU de destino antes dos softwares corporativos (procedimento da
    # empresa: as políticas de grupo são aplicadas pela OU). A mudança é feita pelo técnico no DC01;
    # o script confere e, enquanto não estiver na OU, avisa e espera de novo.
    $config = Get-DomainConfig
    if ([string]::IsNullOrWhiteSpace($config.TargetOu)) {
        throw "Configuração do domínio sem o campo 'targetOu': $domainConfigFile"
    }

    $distinguishedName = Get-ComputerDistinguishedName
    if (-not (Test-ComputerInOu -DistinguishedName $distinguishedName -TargetOu $config.TargetOu)) {
        # A localização gravada pode estar desatualizada: atualiza as políticas antes de pedir a mudança.
        Update-ComputerPolicy
        $distinguishedName = Get-ComputerDistinguishedName
    }

    while (-not (Test-ComputerInOu -DistinguishedName $distinguishedName -TargetOu $config.TargetOu)) {
        Write-Log "O computador não está na OU de destino. Local atual: $distinguishedName" -Level WARN
        Show-OuMoveHelp -Config $config -DistinguishedName $distinguishedName
        $null = Read-Host '  Pressione ENTER depois de mover o computador'
        Update-ComputerPolicy
        $distinguishedName = Get-ComputerDistinguishedName
    }
    Write-Log "Computador na OU de destino: $distinguishedName."
}

function Test-ComputerNamePattern {
    # Confere o nome definido pelo técnico com o padrão da empresa. Só gera aviso: o nome é manual.
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] $Config
    )
    if ([string]::IsNullOrWhiteSpace($Config.NamePattern) -or $ComputerName -match $Config.NamePattern) {
        return
    }
    Write-Log ("O nome do computador '{0}' está fora do padrão da empresa (ex.: {1}). Confira antes de entregar a máquina." -f `
        $ComputerName, $Config.NameExample) -Level WARN
}

function Get-PendingDomainJoin {
    # O ingresso feito no sysdm.cpl só vale depois do reinício. Antes dele, o Windows já registra:
    #   - Netlogon\JoinDomain: ingresso no domínio pendente;
    #   - ComputerName\ComputerName: o novo nome (o nome em uso fica em ActiveComputerName).
    $nameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
    return [pscustomobject] @{
        IsJoinPending   = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain'
        NewComputerName = [string] (Get-ItemProperty -LiteralPath "$nameKey\ComputerName").ComputerName
        ActiveName      = [string] (Get-ItemProperty -LiteralPath "$nameKey\ActiveComputerName").ComputerName
    }
}

function Repair-DomainJoinAutoLogon {
    # O ingresso no domínio pode gravar DefaultDomainName = <domínio> DEPOIS que o login automático foi
    # ajustado; aí o Windows tentaria entrar como <domínio>\<conta local> e o login automático falharia.
    # Confere e, se o valor mudou, reconfigura. Retorna $true se o login automático está correto.
    param([Parameter(Mandatory)] [string] $NewComputerName)
    try {
        if (Test-AutoLogonTarget -UserName $env:USERNAME -ComputerName $NewComputerName) {
            return $true
        }
        $state = Get-AutoLogonState
        Write-Log ('O Windows alterou o login automático (AutoAdminLogon={0}, DefaultDomainName={1}); reconfigurando para {2}\{3}.' -f `
            $state.AutoAdminLogon, $state.DefaultDomainName, $NewComputerName, $env:USERNAME) -Level WARN
        Enable-AutoLogon -UserName $env:USERNAME -LogonCount $autoLogonCount -ComputerName $NewComputerName
        return $true
    }
    catch {
        Write-Log "Não foi possível conferir o login automático: $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function Restart-ForDomainJoin {
    # Reconfigura o login automático com o NOVO nome do computador e reinicia para concluir o ingresso.
    # Durante a contagem e logo antes do reinício, confere se o Windows não alterou o login automático.
    param([Parameter(Mandatory)] [string] $NewComputerName)

    $isAutoLogonEnabled = $false
    if ($isAutoLogonAvailable) {
        try {
            Enable-AutoLogon -UserName $env:USERNAME -LogonCount $autoLogonCount -ComputerName $NewComputerName
            $isAutoLogonEnabled = $true
            Write-Log "Login automático reconfigurado para o novo nome do computador ($NewComputerName\$($env:USERNAME))."
        }
        catch {
            Write-Log "Não foi possível reconfigurar o login automático: $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Host ''
    Write-Host "  Ingresso no domínio detectado (novo nome do computador: $NewComputerName)." -ForegroundColor Green
    Write-Host "  O computador será reiniciado em $restartCountdownSeconds segundos para concluir o ingresso." -ForegroundColor Yellow
    if ($isAutoLogonEnabled) {
        Write-Host "  Depois do reinício, o Windows entra sozinho na conta local $($env:USERNAME) e o provisionamento continua." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Depois do reinício, faça login na conta local: $NewComputerName\$($env:USERNAME) (ou .\$($env:USERNAME))." -ForegroundColor Yellow
    }
    Write-Host ''

    for ($remaining = $restartCountdownSeconds; $remaining -gt 0; $remaining--) {
        Write-Progress -Activity 'Reiniciando para concluir o ingresso no domínio' -Status "Reinício em $remaining s" -SecondsRemaining $remaining
        if ($isAutoLogonEnabled) {
            [void] (Repair-DomainJoinAutoLogon -NewComputerName $NewComputerName)
        }
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Reiniciando para concluir o ingresso no domínio' -Completed

    if ($isAutoLogonEnabled -and (Repair-DomainJoinAutoLogon -NewComputerName $NewComputerName)) {
        $state = Get-AutoLogonState
        Write-Log ('Login automático conferido antes do reinício: {0}\{1}, AutoLogonCount={2}.' -f $state.DefaultDomainName, $state.DefaultUserName, $state.AutoLogonCount)
    }
    Write-Log 'Reiniciando o computador para concluir o ingresso no domínio.'
    $script:isRestarting = $true
    Restart-Computer -Force
}

function Wait-DomainJoin {
    # Aguarda, sem limite de tempo, o técnico ingressar no domínio pelo sysdm.cpl.
    # Ao detectar o ingresso pendente, reinicia com o login automático já ajustado ao novo nome.
    param(
        [Parameter(Mandatory)] $Config,
        [int] $IntervalSeconds = 2
    )
    while ($true) {
        $pending = Get-PendingDomainJoin
        if ($pending.IsJoinPending) {
            Write-Progress -Activity 'Aguardando o ingresso no domínio' -Completed
            Write-Log "Ingresso no domínio detectado. Nome atual: $($pending.ActiveName); novo nome: $($pending.NewComputerName)."
            Test-ComputerNamePattern -ComputerName $pending.NewComputerName -Config $Config
            Restart-ForDomainJoin -NewComputerName $pending.NewComputerName
            return
        }
        Write-Progress -Activity 'Aguardando o ingresso no domínio' `
            -Status "Última verificação às $(Get-Date -Format 'HH:mm:ss'). Faça o ingresso pelo sysdm.cpl (instruções acima)."
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Get-DomainMembership {
    # Situação atual da máquina: está em um domínio? Qual? Com que nome?
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    return [pscustomobject] @{
        IsJoined     = [bool] $computerSystem.PartOfDomain
        Domain       = [string] $computerSystem.Domain
        ComputerName = [string] $computerSystem.Name
    }
}

function Show-DomainJoinHelp {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Membership
    )
    $domain  = $Config.Domain
    $example = if ($Config.NameExample) { " (ex.: $($Config.NameExample))" } else { '' }
    $current = if ($Membership.IsJoined) { "domínio $($Membership.Domain)" } else { "grupo de trabalho $($Membership.Domain)" }

    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Yellow
    Write-Host "  PARA CONTINUAR O PROVISIONAMENTO, É NECESSÁRIO INGRESSAR NO DOMÍNIO $($domain.ToUpper())." -ForegroundColor Yellow
    Write-Host ('=' * 64) -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Situação atual: computador $($Membership.ComputerName), no $current." -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Como ingressar:' -ForegroundColor Yellow
    Write-Host '    1. Conecte o cabo da rede corporativa.' -ForegroundColor Yellow
    Write-Host '    2. Pressione Win+R, digite sysdm.cpl e pressione ENTER.' -ForegroundColor Yellow
    Write-Host '    3. Na aba "Nome do Computador", clique em "Alterar...".' -ForegroundColor Yellow
    Write-Host "    4. Em `"Nome do computador`", digite o nome no padrão da empresa$example." -ForegroundColor Yellow
    Write-Host "    5. Em `"Membro de`", marque `"Domínio`", digite $domain e clique em OK." -ForegroundColor Yellow
    Write-Host '    6. Informe o usuário e a senha com permissão para ingressar computadores no domínio.' -ForegroundColor Yellow
    Write-Host '    7. Quando o Windows pedir para reiniciar, clique em "Reiniciar Mais Tarde".' -ForegroundColor Yellow
    Write-Host '       Esta janela detecta o ingresso, ajusta o login automático ao novo nome' -ForegroundColor Yellow
    Write-Host '       e reinicia o computador sozinha.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Depois do reinício, o provisionamento confere o ingresso e continua sozinho.' -ForegroundColor Yellow
    Write-Host "  Se o Windows não entrar sozinho, faça login na conta local: .\$($env:USERNAME)" -ForegroundColor Yellow
    Write-Host ''
}

function Confirm-DomainMembership {
    # Etapa de domínio. Por enquanto o ingresso (e o novo nome) são feitos pelo técnico.
    # Retorna $true se a máquina está no domínio esperado. Senão, mostra as instruções e aguarda o
    # ingresso; ao detectá-lo, reinicia (e retorna $false com $isRestarting ligado).
    $config     = Get-DomainConfig
    $membership = Get-DomainMembership

    if ($membership.IsJoined -and $membership.Domain -eq $config.Domain) {
        Write-Log "Máquina no domínio $($membership.Domain) (computador $($membership.ComputerName))."
        Test-ComputerNamePattern -ComputerName $membership.ComputerName -Config $config
        return $true
    }

    if ($membership.IsJoined) {
        Write-Log "A máquina está no domínio $($membership.Domain), mas o esperado é $($config.Domain)." -Level WARN
    }
    else {
        Write-Log "A máquina ainda não está no domínio $($config.Domain) (grupo de trabalho $($membership.Domain)). Aguardando o ingresso pelo técnico." -Level WARN
    }
    Show-DomainJoinHelp -Config $config -Membership $membership
    Wait-DomainJoin -Config $config
    return $false
}

function Start-Provisioning {
    Initialize-ProvisioningWindow

    $isFirstRun = -not (Test-Path -LiteralPath $stateFile)
    $state = Get-ProvisioningState

    if ($state.Status -eq 'Completed') {
        Write-Log "O provisionamento já foi concluído em $($state.UpdatedAt). Nada a fazer."
        Unregister-ResumeTask
        Stop-AutoLogon -RemoveCredential
        Restore-RestartPolicy
        Restore-PowerPolicy
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
    Copy-ProvisioningFile
    Register-ResumeTask
    Initialize-RestartPolicy
    Initialize-PowerPolicy

    # Roda a cada execução: na primeira importa a senha do pendrive; nas retomadas só confirma que ela continua guardada.
    Show-Step -Number 1 -Name 'Login automático'
    Initialize-AutoLogon
    if (Test-RunningFromUsb) {
        Show-UsbRemovalNotice
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

    Show-Step -Number 4 -Name 'Aplicativos'
    if (Test-StepCompleted -State $state -Name 'Install-Applications') {
        Write-Log 'Etapa já concluída anteriormente.'
    }
    else {
        # Falha em aplicativo obrigatório: exit code 1, o que interrompe o provisionamento.
        # Para tentar de novo, basta logoff e login: os aplicativos já instalados são pulados.
        $null = Invoke-Stage -Name 'Install-Applications' -Script 'Install-Applications.ps1'
        Complete-Step -State $state -Name 'Install-Applications'
    }

    # Etapa 5: roda a cada execução até a máquina estar no domínio. O ingresso é feito pelo técnico;
    # a etapa aguarda, reinicia ao detectá-lo e, depois do reinício, confere de novo.
    Show-Step -Number 5 -Name 'Domínio'
    if (Test-StepCompleted -State $state -Name 'Join-Domain') {
        Write-Log 'Etapa já concluída anteriormente.'
    }
    elseif (Confirm-DomainMembership) {
        Complete-Step -State $state -Name 'Join-Domain'
    }
    else {
        # Ingresso detectado: o computador está reiniciando.
        return
    }

    # Etapa 6: o técnico move o computador para a OU de destino no DC01; o script confere.
    Show-Step -Number 6 -Name 'Local no AD (OU)'
    if (Test-StepCompleted -State $state -Name 'Move-ComputerOu') {
        Write-Log 'Etapa já concluída anteriormente.'
    }
    else {
        Confirm-ComputerOu
        Complete-Step -State $state -Name 'Move-ComputerOu'
    }

    # Etapa 7: softwares corporativos. Roda nesta janela (caixa de credencial e confirmação do antivírus).
    # Falha em item obrigatório interrompe o provisionamento; para tentar de novo, basta logoff e login:
    # os itens já instalados são pulados.
    Show-Step -Number 7 -Name 'Softwares corporativos'
    if (Test-StepCompleted -State $state -Name 'Install-CorporateSoftware') {
        Write-Log 'Etapa já concluída anteriormente.'
    }
    else {
        $domainPrefix = (Get-DomainConfig).Domain.Split('.')[0].ToUpperInvariant()
        $isCorporateOk = Install-CorporateSoftware -ConfigFile (Join-Path $rootDir 'config\corporate-apps.json') `
            -LogFile (Join-Path $logDir 'corporate-software.log') -WorkDir (Join-Path $rootDir 'Temp') -DomainPrefix $domainPrefix
        if (-not $isCorporateOk) {
            throw 'Softwares corporativos obrigatórios não foram instalados (veja o resumo acima).'
        }
        Complete-Step -State $state -Name 'Install-CorporateSoftware'
    }

    $state.Status = 'Completed'
    Save-ProvisioningState -State $state
    Unregister-ResumeTask
    Stop-AutoLogon -RemoveCredential
    Restore-RestartPolicy
    Restore-PowerPolicy
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
        Write-Host '  As próximas etapas (configurações) ainda não foram implementadas.' -ForegroundColor Green
        Write-Host "  Log: $logFile" -ForegroundColor Green
        Write-Host ('=' * 64) -ForegroundColor Green
    }
}
catch {
    $exitCode = 1
    Write-Log $_.Exception.Message -Level ERROR
    # Mantém a senha guardada para a nova tentativa (logoff e login), mas não deixa o login automático ligado.
    Stop-AutoLogon
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
