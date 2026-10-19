# Etapa de aplicativos: instala os programas listados em config\apps.json.
# Executada pelo Start-Provisioning.ps1 depois do Windows Update (a internet já foi verificada).
#
# Para cada aplicativo:
#   1. já instalado? → pula;
#   2. baixa do site oficial (somente HTTPS) e valida o hash SHA-256 e/ou a assinatura digital;
#   3. se o download ou a validação falhar, usa a cópia do pendrive (installers\<id>\<arquivo>),
#      copiada para o disco na primeira execução, com a mesma validação;
#   4. instala em modo silencioso e confirma que o programa passou a aparecer como instalado.
#
# Todos os aplicativos são tentados, mesmo que um falhe. Ao final, mostra o resumo na tela.
# Falha em aplicativo obrigatório ("required": true) → exit code 1 (interrompe o provisionamento).
#
# Exit codes: 0 = todos os obrigatórios instalados; 1 = falha.
# Carregado por dot-source (testes), apenas define as funções.
# Compatível com Windows PowerShell 5.1.

param(
    # Pasta de trabalho do provisionamento. Só muda em testes.
    [ValidateNotNullOrEmpty()] [string] $RootDir = 'C:\ProgramData\WorkstationProvisioning'
)

$ErrorActionPreference = 'Stop'
# A barra de progresso do Invoke-WebRequest deixa o download muito lento no PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

$configFile    = Join-Path $RootDir 'config\apps.json'
$installersDir = Join-Path $RootDir 'installers'
$downloadDir   = Join-Path $RootDir 'Downloads'
$logDir        = Join-Path $RootDir 'Logs'
$logFile       = Join-Path $logDir 'applications.log'

$downloadRetries           = 3
$downloadRetryDelaySeconds = 30
$downloadTimeoutSeconds    = 600

# 1618: outra instalação do Windows (MSI) em andamento. Aguarda e tenta de novo.
$installerBusyExitCode     = 1618
$installerBusyRetries      = 10
$installerBusyDelaySeconds = 30

# 0 = sucesso; 3010 e 1641 = sucesso com reinicialização pendente.
$msiSuccessExitCodes     = @(0, 3010, 1641)
$defaultExeSuccessCodes  = @(0, 3010)
$rebootPendingExitCodes  = @(3010, 1641)

$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Write-Detail {
    # Registra somente no applications.log.
    param([Parameter(Mandatory)] [string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Write-Status {
    # Mensagem para o técnico (janela + deployment.log, via orquestrador) e para o applications.log.
    # Escreve direto na saída padrão para não se misturar ao valor de retorno das funções.
    param([Parameter(Mandatory)] [string] $Message)
    [Console]::Out.WriteLine($Message)
    Write-Detail $Message
}

function Read-ApplicationList {
    # Lê e valida o config\apps.json. Erro de configuração interrompe a etapa.
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Lista de aplicativos não encontrada: $configFile"
    }
    try {
        $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Lista de aplicativos inválida (JSON): $configFile. $($_.Exception.Message)"
    }

    $applications = @($config.applications)
    if ($applications.Count -eq 0) {
        throw "Nenhum aplicativo em $configFile."
    }

    foreach ($application in $applications) {
        foreach ($field in 'id', 'name', 'type', 'url', 'fileName', 'displayName') {
            if ([string]::IsNullOrWhiteSpace([string] $application.$field)) {
                throw "Aplicativo '$($application.name)' sem o campo '$field' em $configFile."
            }
        }
        if ($application.type -notin 'msi', 'exe') {
            throw "Aplicativo '$($application.name)': tipo '$($application.type)' inválido (use 'msi' ou 'exe')."
        }
        if ($application.url -notlike 'https://*') {
            throw "Aplicativo '$($application.name)': o endereço precisa usar HTTPS ($($application.url))."
        }
        if ([string]::IsNullOrWhiteSpace($application.sha256) -and [string]::IsNullOrWhiteSpace($application.signer)) {
            throw "Aplicativo '$($application.name)': informe 'sha256' e/ou 'signer' para validar o instalador."
        }
        if ($application.type -eq 'exe' -and [string]::IsNullOrWhiteSpace($application.arguments)) {
            throw "Aplicativo '$($application.name)': instalador EXE exige 'arguments' com a opção de instalação silenciosa."
        }
        if ($null -eq $application.required -or $application.required -isnot [bool]) {
            throw "Aplicativo '$($application.name)': o campo 'required' precisa ser true ou false."
        }
    }
    return , $applications
}

function Get-InstalledProgramName {
    # Nomes dos programas instalados (registro "Programas e Recursos", 64 e 32 bits).
    $names = foreach ($key in $uninstallKeys) {
        Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] } |
            ForEach-Object { $_.DisplayName }
    }
    return , @($names | Where-Object { $_ })
}

function Test-ApplicationInstalled {
    param([Parameter(Mandatory)] $Application)
    $installedNames = Get-InstalledProgramName
    $matchingNames  = @($installedNames | Where-Object { $_ -like $Application.displayName })
    return $matchingNames.Count -gt 0
}

function Save-InstallerFile {
    # Baixa o instalador por HTTPS, com novas tentativas.
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Path
    )
    if ($Url -notlike 'https://*') {
        throw "endereço não usa HTTPS: $Url"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null

    for ($attempt = 1; $attempt -le $downloadRetries; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec $downloadTimeoutSeconds
            return
        }
        catch {
            $message = $_.Exception.Message
            # Inspeção SSL do firewall corporativo: o certificado apresentado não é confiável nesta máquina.
            if ($message -match 'SSL|TLS|confiança|trust') {
                $message += ' (provável inspeção SSL do firewall da rede)'
            }
            Write-Detail ('Download falhou (tentativa {0} de {1}): {2} - {3}' -f $attempt, $downloadRetries, $Url, $message)
            if ($attempt -eq $downloadRetries) {
                throw $message
            }
            Start-Sleep -Seconds $downloadRetryDelaySeconds
        }
    }
}

function Assert-InstallerFile {
    # Valida o instalador pelo hash SHA-256 e/ou pela assinatura digital. Lança erro com o motivo se for inválido.
    param(
        [Parameter(Mandatory)] $Application,
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not [string]::IsNullOrWhiteSpace($Application.sha256)) {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($hash -ne $Application.sha256.Trim().ToUpperInvariant()) {
            throw "hash SHA-256 diferente do esperado (obtido $hash)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Application.signer)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ([string] $signature.Status -ne 'Valid') {
            throw "assinatura digital inválida ($($signature.Status))"
        }
        $signerName = if ($signature.SignerCertificate.Subject -match '(?:^|,\s*)CN=([^,]+)') { $Matches[1].Trim() } else { '' }
        if ($signerName -ne $Application.signer) {
            throw "assinado por '$signerName', esperado '$($Application.signer)'"
        }
    }
}

function Get-ApplicationInstaller {
    # Obtém um instalador válido: primeiro o download oficial; se falhar, a cópia do pendrive.
    # Retorna Path, Source ('download' ou 'pendrive') e IsTemporary. Lança erro com os motivos se nenhum servir.
    param([Parameter(Mandatory)] $Application)

    $reasons = @()

    $downloadPath = Join-Path $downloadDir $Application.fileName
    try {
        Save-InstallerFile -Url $Application.url -Path $downloadPath
        Assert-InstallerFile -Application $Application -Path $downloadPath
        return [pscustomobject] @{ Path = $downloadPath; Source = 'download'; IsTemporary = $true }
    }
    catch {
        $reasons += "download: $($_.Exception.Message)"
        Write-Status "AVISO: $($Application.name): download indisponível ($($_.Exception.Message)). Tentando a cópia do pendrive."
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force
        }
    }

    $localPath = Join-Path (Join-Path $installersDir $Application.id) $Application.fileName
    if (-not (Test-Path -LiteralPath $localPath)) {
        $reasons += "pendrive: arquivo não encontrado ($localPath)"
        throw ($reasons -join '; ')
    }
    try {
        Assert-InstallerFile -Application $Application -Path $localPath
        return [pscustomobject] @{ Path = $localPath; Source = 'pendrive'; IsTemporary = $false }
    }
    catch {
        $reasons += "pendrive: $($_.Exception.Message)"
        throw ($reasons -join '; ')
    }
}

function Invoke-ApplicationInstaller {
    # Executa o instalador em modo silencioso e retorna o exit code.
    param(
        [Parameter(Mandatory)] $Application,
        [Parameter(Mandatory)] [string] $InstallerPath
    )
    if ($Application.type -eq 'msi') {
        $msiLog    = Join-Path $logDir ('msi-{0}.log' -f $Application.id)
        $arguments = $Application.arguments
        if ([string]::IsNullOrWhiteSpace($arguments)) { $arguments = '/qn /norestart' }
        $filePath     = 'msiexec.exe'
        $argumentLine = '/i "{0}" {1} /l*v "{2}"' -f $InstallerPath, $arguments, $msiLog
    }
    else {
        $filePath     = $InstallerPath
        $argumentLine = $Application.arguments
    }

    for ($attempt = 1; $attempt -le $installerBusyRetries; $attempt++) {
        Write-Detail "Executando: $filePath $argumentLine"
        $process = Start-Process -FilePath $filePath -ArgumentList $argumentLine -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne $installerBusyExitCode) {
            return $process.ExitCode
        }
        Write-Status "AVISO: $($Application.name): outra instalação do Windows está em andamento. Nova tentativa em $installerBusyDelaySeconds s ($attempt de $installerBusyRetries)."
        Start-Sleep -Seconds $installerBusyDelaySeconds
    }
    throw "outra instalação do Windows continuou em andamento (exit code $installerBusyExitCode) após $installerBusyRetries tentativas"
}

function Install-Application {
    # Instala um aplicativo e retorna o resultado (Name, Required, Status, Source, Message).
    # Status: AlreadyInstalled, Installed ou Failed. Nunca lança erro: a falha vai no resultado.
    param([Parameter(Mandatory)] $Application)

    $result = [pscustomobject] @{
        Name     = $Application.name
        Required = [bool] $Application.required
        Status   = ''
        Source   = ''
        Message  = ''
    }

    if (Test-ApplicationInstalled -Application $Application) {
        $result.Status = 'AlreadyInstalled'
        Write-Status "$($Application.name): já está instalado."
        return $result
    }

    $installer = $null
    try {
        Write-Status "$($Application.name): obtendo o instalador..."
        $installer = Get-ApplicationInstaller -Application $Application
        $result.Source = $installer.Source

        Write-Status "$($Application.name): instalando (origem: $($installer.Source))..."
        $exitCode = Invoke-ApplicationInstaller -Application $Application -InstallerPath $installer.Path

        $successCodes = if ($Application.type -eq 'msi') {
            $msiSuccessExitCodes
        }
        elseif ($Application.successExitCodes) {
            @($Application.successExitCodes)
        }
        else {
            $defaultExeSuccessCodes
        }
        if ($exitCode -notin $successCodes) {
            throw "o instalador terminou com exit code $exitCode (detalhes em $logDir)"
        }
        if (-not (Test-ApplicationInstalled -Application $Application)) {
            throw "o instalador terminou sem erro, mas o programa não aparece como instalado"
        }

        $result.Status = 'Installed'
        if ($exitCode -in $rebootPendingExitCodes) {
            $result.Message = 'reinicialização pendente'
        }
        Write-Status "$($Application.name): instalado."
    }
    catch {
        $result.Status  = 'Failed'
        $result.Message = $_.Exception.Message
        Write-Detail "Falha em $($Application.name): $($result.Message)"
    }
    finally {
        if ($installer -and $installer.IsTemporary -and (Test-Path -LiteralPath $installer.Path)) {
            Remove-Item -LiteralPath $installer.Path -Force
        }
    }
    return $result
}

function Show-ApplicationSummary {
    # Resumo final na tela. Linhas com [FALHA] aparecem em vermelho na janela do provisionamento.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results)

    Write-Status 'Resumo dos aplicativos:'
    foreach ($result in $Results) {
        $optionalTag = if ($result.Required) { '' } else { ' (opcional)' }
        switch ($result.Status) {
            'Installed' {
                $note = if ($result.Message) { "; $($result.Message)" } else { '' }
                Write-Status ('  [OK]         {0} - instalado (origem: {1}{2})' -f $result.Name, $result.Source, $note)
            }
            'AlreadyInstalled' {
                Write-Status ('  [JÁ HAVIA]   {0} - já estava instalado' -f $result.Name)
            }
            default {
                Write-Status ('  [FALHA]      {0}{1} - {2}' -f $result.Name, $optionalTag, $result.Message)
            }
        }
    }
}

function Install-Applications {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Write-Detail '==== Início da etapa de aplicativos ===='

    $applications = Read-ApplicationList
    Write-Status ('Aplicativos: {0}' -f (($applications | ForEach-Object { $_.name }) -join ', '))

    # Todos são tentados, mesmo que um falhe, para o técnico ver de uma vez tudo o que deu errado.
    $results = @(foreach ($application in $applications) {
        Install-Application -Application $application
    })

    Show-ApplicationSummary -Results $results

    $failedRequired = @($results | Where-Object { $_.Status -eq 'Failed' -and $_.Required })
    $failedOptional = @($results | Where-Object { $_.Status -eq 'Failed' -and -not $_.Required })

    if ($failedOptional.Count -gt 0) {
        Write-Status ('AVISO: aplicativo(s) opcional(is) não instalado(s): {0}.' -f (($failedOptional | ForEach-Object { $_.Name }) -join ', '))
    }
    if ($failedRequired.Count -gt 0) {
        Write-Status ('ERRO: aplicativo(s) obrigatório(s) não instalado(s): {0}. Detalhes em {1}.' -f `
            (($failedRequired | ForEach-Object { $_.Name }) -join ', '), $logFile)
        return 1
    }
    return 0
}

# Só roda quando o script é executado, não quando é carregado por dot-source (testes).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # @(...)[-1]: garante que só o código de saída seja usado, mesmo que algo escape para o pipeline.
        $exitCode = @(Install-Applications)[-1]
        exit $exitCode
    }
    catch {
        [Console]::Out.WriteLine("ERRO: $($_.Exception.Message)")
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Write-Detail "ERRO: $($_.Exception.Message)"
        exit 1
    }
}
