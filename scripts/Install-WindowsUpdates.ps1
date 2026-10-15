# Etapa de Windows Update: executa UM ciclo (procurar → baixar → instalar).
# Executada pelo Start-Provisioning.ps1 somente depois que Test-InternetConnection confirmar acesso à internet.
# O orquestrador repete os ciclos e cuida dos reboots; este script nunca reinicia a máquina.
#
# Usa a API nativa do Windows Update (Windows Update Agent, objeto COM Microsoft.Update.Session).
# As mensagens de progresso aparecem na janela do provisionamento e no deployment.log.
# O detalhe de cada atualização vai para Logs\windows-update.log.
#
# Exit codes:
#   0    = nenhuma atualização a instalar (Windows Update concluído)
#   2    = atualizações processadas, sem necessidade de reiniciar (o orquestrador procura de novo)
#   3010 = reinicialização necessária
#   1    = falha
#
# Teste sem alterar a máquina:
#   powershell.exe -ExecutionPolicy Bypass -File .\Install-WindowsUpdates.ps1 -SearchOnly
#
# Carregado por dot-source (testes), apenas define as funções: o ciclo só roda quando o script é executado.
#
# Compatível com Windows PowerShell 5.1.

param(
    # Apenas procura e lista as atualizações, sem baixar nem instalar.
    [switch] $SearchOnly,
    # Não inclui drivers na busca (padrão: inclui).
    [switch] $ExcludeDrivers,
    # Não inclui atualizações opcionais (padrão: inclui).
    [switch] $ExcludeOptional,
    # Pasta de trabalho do provisionamento. Só muda em testes.
    [ValidateNotNullOrEmpty()] [string] $RootDir = 'C:\ProgramData\WorkstationProvisioning'
)

$ErrorActionPreference = 'Stop'

$logFile      = Join-Path $RootDir 'Logs\windows-update.log'
$failuresFile = Join-Path $RootDir 'windows-update-failures.json'

$maxFailuresPerUpdate    = 2
$searchRetries           = 3
$searchRetryDelaySeconds = 60
$minFreeSpaceGB          = 10

# Categoria "Upgrades" (atualizações de versão do Windows). ID fixo, independente do idioma.
# A versão do Windows deve vir da ISO, então essas atualizações nunca são instaladas.
$upgradesCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'

# Atualizações prévias: a API não tem um campo próprio; o filtro é pelo título (inglês e português).
$previewTitlePattern = '(?i)\bpreview\b|visualiza[çc][ãa]o|pr[ée]via'

# Tipo da atualização na API (IUpdate.Type): 1 = software, 2 = driver.
$updateTypeDriver = 2

$exitNoUpdates      = 0
$exitInstalled      = 2
$exitRebootRequired = 3010

function Write-Detail {
    # Registra somente no windows-update.log.
    param([Parameter(Mandatory)] [string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Write-Status {
    # Mensagem para o técnico (janela + deployment.log, via orquestrador) e para o windows-update.log.
    # Escreve direto na saída padrão para não se misturar ao valor de retorno das funções.
    param([Parameter(Mandatory)] [string] $Message)
    [Console]::Out.WriteLine($Message)
    Write-Detail $Message
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal] $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UpdateLabel {
    param([Parameter(Mandatory)] $Update)
    $kb = if ($Update.KBArticleIDs.Count -gt 0) { 'KB' + $Update.KBArticleIDs.Item(0) } else { 'sem KB' }
    return '{0} - {1}' -f $kb, $Update.Title
}

function Assert-Prerequisite {
    if (-not $SearchOnly -and -not (Test-IsAdministrator)) {
        throw 'A instalação de atualizações exige execução como administrador.'
    }

    $service = Get-Service -Name 'wuauserv'
    if ($service.StartType -eq 'Disabled') {
        throw 'O serviço Windows Update (wuauserv) está desativado.'
    }
    if (-not $SearchOnly -and $service.Status -ne 'Running') {
        Start-Service -Name 'wuauserv'
    }

    $freeSpaceGB = [math]::Round((Get-PSDrive -Name 'C').Free / 1GB, 1)
    if ($freeSpaceGB -lt $minFreeSpaceGB) {
        Write-Status "AVISO: apenas $freeSpaceGB GB livres em C: (recomendado: $minFreeSpaceGB GB)."
    }
}

function Get-UpdateFailureCount {
    # Quantas vezes cada atualização (por UpdateID) já falhou em ciclos anteriores.
    $counts = @{}
    if (Test-Path -LiteralPath $failuresFile) {
        $data = Get-Content -LiteralPath $failuresFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $data.PSObject.Properties) {
            $counts[$property.Name] = [int] $property.Value
        }
    }
    return $counts
}

function Save-UpdateFailureCount {
    param([Parameter(Mandatory)] [hashtable] $Counts)
    $Counts | ConvertTo-Json | Set-Content -LiteralPath $failuresFile -Encoding UTF8
}

function Find-PendingUpdate {
    param([Parameter(Mandatory)] $Session)

    $searcher = $Session.CreateUpdateSearcher()
    $criteriaList = @("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if (-not $ExcludeDrivers) {
        $criteriaList += "IsInstalled=0 and IsHidden=0 and Type='Driver'"
    }

    # UpdateID → atualização (evita duplicados entre as buscas).
    # [ordered] mantém a ordem devolvida pelo Windows Update (ex.: pilha de manutenção antes das demais).
    $updatesById = [ordered] @{}
    foreach ($criteria in $criteriaList) {
        $searchResult = $null
        for ($attempt = 1; $attempt -le $searchRetries; $attempt++) {
            try {
                $searchResult = $searcher.Search($criteria)
                break
            }
            catch {
                Write-Status ('Falha na busca (tentativa {0} de {1}): {2}' -f $attempt, $searchRetries, $_.Exception.Message)
                if ($attempt -eq $searchRetries) {
                    throw "Não foi possível procurar atualizações após $searchRetries tentativas."
                }
                Start-Sleep -Seconds $searchRetryDelaySeconds
            }
        }
        foreach ($update in $searchResult.Updates) {
            $updatesById[$update.Identity.UpdateID] = $update
        }
    }
    return , @($updatesById.Values)
}

function Select-InstallableUpdate {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Updates,
        [Parameter(Mandatory)] [hashtable] $FailureCounts
    )

    $selected       = New-Object System.Collections.Generic.List[object]
    $skippedReasons = [ordered] @{}   # motivo → quantidade, para o resumo na tela

    foreach ($update in $Updates) {
        $label    = Get-UpdateLabel -Update $update
        $isDriver = $update.Type -eq $updateTypeDriver

        $isUpgrade = $false
        foreach ($category in $update.Categories) {
            if ($category.CategoryID -eq $upgradesCategoryId) { $isUpgrade = $true }
        }

        $reason = $null
        if ($isUpgrade) {
            $reason = 'atualização de versão do Windows (a versão vem da ISO)'
        }
        elseif ($update.Title -match $previewTitlePattern) {
            $reason = 'atualização prévia'
        }
        elseif ($ExcludeOptional -and $update.BrowseOnly) {
            $reason = 'opcional (excluída por parâmetro)'
        }
        elseif ($update.InstallationBehavior.CanRequestUserInput -and -not $isDriver) {
            # Só para software: nesse caso a marcação costuma ser real e a instalação poderia travar
            # esperando um clique. Drivers com essa marcação são instalados (ver abaixo).
            $reason = 'software que pode pedir interação do usuário'
        }
        elseif ($FailureCounts[$update.Identity.UpdateID] -ge $maxFailuresPerUpdate) {
            $reason = "falhou $maxFailuresPerUpdate vezes em ciclos anteriores"
            Write-Status "AVISO: ignorando $label ($reason)."
        }

        if ($reason) {
            Write-Detail "Ignorada: $label ($reason)"
            $skippedReasons[$reason] = 1 + [int] $skippedReasons[$reason]
            continue
        }

        if ($isDriver -and $update.InstallationBehavior.CanRequestUserInput) {
            # Muitos drivers (ex.: Intel) vêm marcados como "pode pedir interação", mas o Windows Update
            # os instala sem janela. A instalação usa ForceQuiet: se o driver realmente exigir interação,
            # ele falha em vez de travar, e depois de $maxFailuresPerUpdate falhas passa a ser ignorado.
            Write-Detail "Driver marcado como 'pode pedir interação'; será instalado em modo silencioso: $label"
        }
        $selected.Add($update)
    }

    foreach ($reason in $skippedReasons.Keys) {
        Write-Status ('Ignoradas por "{0}": {1}' -f $reason, $skippedReasons[$reason])
    }
    return , $selected.ToArray()
}

function Install-WindowsUpdates {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logFile) | Out-Null
    Write-Detail ('==== Início do ciclo (SearchOnly={0}, ExcludeDrivers={1}, ExcludeOptional={2}) ====' -f $SearchOnly, $ExcludeDrivers, $ExcludeOptional)

    Assert-Prerequisite

    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = 'WorkstationProvisioning'

    if (-not $SearchOnly) {
        $systemInfo = New-Object -ComObject 'Microsoft.Update.SystemInfo'
        if ($systemInfo.RebootRequired) {
            Write-Status 'Há uma reinicialização pendente de uma instalação anterior.'
            return $exitRebootRequired
        }
    }

    Write-Status 'Procurando atualizações (pode levar alguns minutos)...'
    $foundUpdates  = Find-PendingUpdate -Session $session
    $failureCounts = Get-UpdateFailureCount
    $updates       = Select-InstallableUpdate -Updates $foundUpdates -FailureCounts $failureCounts

    Write-Status ('Encontradas: {0} | a instalar: {1} | ignoradas: {2} (detalhes no windows-update.log)' -f `
        $foundUpdates.Count, $updates.Count, ($foundUpdates.Count - $updates.Count))

    if ($updates.Count -eq 0) {
        Write-Status 'Nenhuma atualização a instalar.'
        return $exitNoUpdates
    }

    for ($i = 0; $i -lt $updates.Count; $i++) {
        $optionalTag = if ($updates[$i].BrowseOnly) { ' [opcional]' } else { '' }
        Write-Status ('  {0,2}. {1}{2}' -f ($i + 1), (Get-UpdateLabel -Update $updates[$i]), $optionalTag)
    }

    if ($SearchOnly) {
        Write-Status 'Modo -SearchOnly: nada foi baixado ou instalado.'
        return $exitNoUpdates
    }

    $downloader = $session.CreateUpdateDownloader()
    $installer  = $session.CreateUpdateInstaller()
    $installer.ForceQuiet = $true

    $installedCount   = 0
    $failedCount      = 0
    $isRebootRequired = $false
    $total            = $updates.Count

    # Uma atualização por vez: progresso visível e uma falha não interrompe as demais.
    for ($i = 0; $i -lt $total; $i++) {
        $update   = $updates[$i]
        $updateId = $update.Identity.UpdateID
        $label    = Get-UpdateLabel -Update $update
        $prefix   = '[{0}/{1}]' -f ($i + 1), $total

        try {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
            }

            $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
            [void] $collection.Add($update)

            if (-not $update.IsDownloaded) {
                Write-Status "$prefix Baixando: $label"
                $downloader.Updates = $collection
                $downloadResult = $downloader.Download()
                # ResultCode: 2 = sucesso, 3 = sucesso com erros.
                if ($downloadResult.ResultCode -notin 2, 3) {
                    throw ('download terminou com ResultCode {0} (HResult 0x{1:X8})' -f $downloadResult.ResultCode, $downloadResult.HResult)
                }
            }

            Write-Status "$prefix Instalando: $label"
            $installer.Updates = $collection
            $installResult = $installer.Install()
            $updateResult  = $installResult.GetUpdateResult(0)
            if ($updateResult.ResultCode -notin 2, 3) {
                throw ('instalação terminou com ResultCode {0} (HResult 0x{1:X8})' -f $updateResult.ResultCode, $updateResult.HResult)
            }

            $installedCount++
            $failureCounts.Remove($updateId)
            if ($updateResult.RebootRequired) {
                $isRebootRequired = $true
                Write-Status "$prefix Instalada (requer reinicialização)."
            }
            else {
                Write-Status "$prefix Instalada."
            }
        }
        catch {
            $failedCount++
            $failureCounts[$updateId] = 1 + [int] $failureCounts[$updateId]

            # Erros da API (COM) chegam embrulhados em uma ou mais exceções: o código útil é o da mais interna.
            # Erros gerados pelo próprio script já trazem o HResult do Windows Update na mensagem.
            $message = $_.Exception.Message
            if ($message -notlike '*HResult*') {
                $message = '{0} (HResult 0x{1:X8})' -f $message, $_.Exception.GetBaseException().HResult
            }
            Write-Status ('{0} FALHA: {1} - {2}' -f $prefix, $label, $message)
        }
    }

    Save-UpdateFailureCount -Counts $failureCounts

    # Confirma pelo próprio Windows se há reinicialização pendente.
    if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired) {
        $isRebootRequired = $true
    }

    Write-Status ('Resumo do ciclo: {0} instaladas, {1} com falha, reinicialização necessária: {2}.' -f `
        $installedCount, $failedCount, $(if ($isRebootRequired) { 'sim' } else { 'não' }))

    if ($isRebootRequired) { return $exitRebootRequired }
    return $exitInstalled
}

# Só roda quando o script é executado, não quando é carregado por dot-source (testes).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # @(...)[-1]: garante que só o código de saída seja usado, mesmo que algo escape para o pipeline.
        $exitCode = @(Install-WindowsUpdates)[-1]
        exit $exitCode
    }
    catch {
        [Console]::Out.WriteLine("ERRO: $($_.Exception.Message)")
        Write-Detail "ERRO: $($_.Exception.Message)"
        exit 1
    }
}
