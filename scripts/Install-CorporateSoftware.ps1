# Etapa 7: softwares corporativos (Office, antivírus WithSecure, Everest 3.0, Everest 2.11 + BDE).
# Carregado pelo Start-Provisioning.ps1 (dot-source) e executado DENTRO da janela do provisionamento,
# porque tem interação com o técnico (caixa de credencial do Windows e confirmação da licença do antivírus).
#
# Lista de itens, em ordem: config\corporate-apps.json. Office: config\office-odt.xml (ODT).
#
# Acesso aos instaladores: a máquina entra com a conta LOCAL Laquila, que não acessa os compartilhamentos
# do domínio. O técnico digita uma credencial do domínio na caixa do Windows; ela é usada para conectar aos
# compartilhamentos (New-SmbMapping), fica só na memória e as conexões são removidas no final.
#
# Para cada item: já instalado? → pula; senão executa, confere e registra. Todos os itens são tentados.
# Ao final, resumo na tela: [OK], [JÁ HAVIA], [PULADO] e [FALHA].
#
# As variáveis e funções têm nomes próprios (Corporate*) para não colidir com as do orquestrador.
# Compatível com Windows PowerShell 5.1.

$script:corporateLogFile   = $null
$corporateCredentialTries  = 3
$corporateExeSuccessCodes  = @(0, 3010, 1641)
$corporateItemTypes        = @('odt', 'exe', 'msi', 'bat', 'copy-folder', 'copy-file', 'shortcuts', 'registry')
$corporateRegistryKinds    = @('String', 'ExpandString', 'DWord', 'QWord')
# Botões das regras de 'prompts': o instalador pode estar em inglês e o Windows em português.
$corporateButtonAliases    = @{
    'OK'     = @('OK')
    'YES'    = @('Yes', 'Sim')
    'NO'     = @('No', 'Não')
    'CANCEL' = @('Cancel', 'Cancelar')
}
$corporateUninstallKeys    = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Write-CorporateDetail {
    # Registra somente no corporate-software.log.
    param([Parameter(Mandatory)] [string] $Message)
    if ($script:corporateLogFile) {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:corporateLogFile -Value $line -Encoding UTF8
    }
}

function Write-CorporateStatus {
    # Mensagem para o técnico: na janela e no deployment.log (via Write-Log do orquestrador) e no log da etapa.
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    if (Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
        Write-Log $Message -Level $Level
    }
    else {
        Write-Host $Message
    }
    Write-CorporateDetail "[$Level] $Message"
}

function Read-CorporateConfig {
    # Lê e valida o config\corporate-apps.json. Erro de configuração interrompe a etapa.
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Lista de softwares corporativos não encontrada: $Path"
    }
    try {
        $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Lista de softwares corporativos inválida (JSON): $Path. $($_.Exception.Message)"
    }

    $items = @($config.items)
    if ($items.Count -eq 0) {
        throw "Nenhum item em $Path."
    }
    foreach ($item in $items) {
        foreach ($field in 'id', 'name', 'type') {
            if ([string]::IsNullOrWhiteSpace([string] $item.$field)) {
                throw "Item '$($item.name)' sem o campo '$field' em $Path."
            }
        }
        if ($item.type -notin $corporateItemTypes) {
            throw "Item '$($item.name)': tipo '$($item.type)' inválido (use: $($corporateItemTypes -join ', '))."
        }
        if ($null -eq $item.required -or $item.required -isnot [bool]) {
            throw "Item '$($item.name)': o campo 'required' precisa ser true ou false."
        }
        $requiredFields = switch ($item.type) {
            'odt'         { @('path', 'odtConfig') }
            'bat'         { @('path') }
            'msi'         { @('path') }
            'registry'    { @('key', 'values') }
            'copy-folder' { @('source', 'destination') }
            'copy-file'   { @('source') }
            'shortcuts'   { @('destination', 'shortcuts') }
            default       { @() }
        }
        foreach ($field in $requiredFields) {
            if ($null -eq $item.$field -or ($item.$field -is [string] -and [string]::IsNullOrWhiteSpace($item.$field))) {
                throw "Item '$($item.name)' (tipo $($item.type)) sem o campo '$field' em $Path."
            }
        }
        if ($item.type -eq 'exe' -and [string]::IsNullOrWhiteSpace($item.path) -and [string]::IsNullOrWhiteSpace($item.pathPattern)) {
            throw "Item '$($item.name)' (tipo exe) sem 'path' nem 'pathPattern' em $Path."
        }
        if ($item.type -eq 'copy-file') {
            $hasDestination = -not [string]::IsNullOrWhiteSpace($item.destination)
            $hasRegistry    = $null -ne $item.destinationRegistry -and $item.destinationRegistry.key -and $item.destinationRegistry.value
            if (-not ($hasDestination -or $hasRegistry)) {
                throw "Item '$($item.name)' (tipo copy-file) sem 'destination' nem 'destinationRegistry' (key e value) em $Path."
            }
        }
        if ($item.sha256 -and [string] $item.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Item '$($item.name)': 'sha256' precisa ter 64 caracteres hexadecimais."
        }
        foreach ($entry in @($item.values | Where-Object { $_ })) {
            if ([string]::IsNullOrWhiteSpace($entry.name) -or $entry.kind -notin $corporateRegistryKinds -or $null -eq $entry.value) {
                throw "Item '$($item.name)': cada valor de 'values' precisa de 'name', 'value' e 'kind' ($($corporateRegistryKinds -join ', '))."
            }
        }
        # Janelas que o instalador mostra mesmo no modo silencioso, respondidas sozinhas: { text (regex), button }.
        foreach ($prompt in @($item.prompts | Where-Object { $_ })) {
            if ([string]::IsNullOrWhiteSpace($prompt.text) -or [string]::IsNullOrWhiteSpace($prompt.button)) {
                throw "Item '$($item.name)': cada regra de 'prompts' precisa de 'text' e 'button'."
            }
            try { [void] [regex]::new($prompt.text) }
            catch { throw "Item '$($item.name)': 'prompts.text' não é uma expressão válida: $($prompt.text)" }
        }
        if ($null -ne $item.detect -and $item.detect.minimumVersion) {
            $minimumVersion = $null
            if (-not $item.detect.path -or -not [version]::TryParse([string] $item.detect.minimumVersion, [ref] $minimumVersion)) {
                throw "Item '$($item.name)': 'detect.minimumVersion' precisa de 'detect.path' e de uma versão válida (ex.: 16.0.17000.0)."
            }
        }
    }
    return [pscustomobject] @{ Shares = @($config.shares); Items = $items }
}

function Resolve-CorporateItemPath {
    # Caminho do instalador: 'path' direto ou 'pathPattern' (curinga), que precisa achar exatamente um arquivo.
    param([Parameter(Mandatory)] $Item)
    if (-not [string]::IsNullOrWhiteSpace($Item.path)) {
        if (-not (Test-Path -LiteralPath $Item.path)) {
            throw "instalador não encontrado: $($Item.path)"
        }
        return $Item.path
    }
    $found = @(Get-ChildItem -Path $Item.pathPattern -File -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) {
        throw ("o padrão '{0}' encontrou {1} arquivo(s); precisa encontrar exatamente 1" -f $Item.pathPattern, $found.Count)
    }
    return $found[0].FullName
}

function Get-CorporateInstalledProgramName {
    # Nomes em "Programas e Recursos" (64 e 32 bits).
    $names = foreach ($key in $corporateUninstallKeys) {
        Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] } |
            ForEach-Object { $_.DisplayName }
    }
    return , @($names | Where-Object { $_ })
}

function Get-CorporateFileVersion {
    # Versão do arquivo (ex.: WINWORD.EXE 16.0.19127.20154) ou $null se não tiver.
    param([Parameter(Mandatory)] [string] $Path)
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    if ($info.FileMajorPart -eq 0 -and $info.FileMinorPart -eq 0 -and $info.FileBuildPart -eq 0) {
        return $null
    }
    return [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

function Test-CorporateItemInstalled {
    # Item sem 'detect' é sempre executado (ex.: cópia de configuração e atalhos, que podem ser refeitos).
    param([Parameter(Mandatory)] $Item)
    if ($null -eq $Item.detect) {
        return $false
    }
    if ($Item.detect.path) {
        # 'path' pode ser uma lista: basta um existir (ex.: o BDE pode estar em mais de uma pasta).
        $existing = @($Item.detect.path) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $existing) {
            return $false
        }
        if (-not $Item.detect.minimumVersion) {
            return $true
        }
        # Com minimumVersion, uma versão antiga instalada conta como "não instalado" (ex.: Office de 2019).
        $installedVersion = Get-CorporateFileVersion -Path $existing
        $isCurrent = $null -ne $installedVersion -and $installedVersion -ge [version] $Item.detect.minimumVersion
        if (-not $isCurrent) {
            Write-CorporateDetail ("{0}: versão {1} encontrada, mínima {2}." -f $Item.name, $installedVersion, $Item.detect.minimumVersion)
        }
        return $isCurrent
    }
    if ($Item.detect.displayName) {
        $installedNames = Get-CorporateInstalledProgramName
        return @($installedNames | Where-Object { $_ -like $Item.detect.displayName }).Count -gt 0
    }
    return $false
}

function Connect-CorporateShare {
    # Pede a credencial do domínio na caixa do Windows e conecta aos compartilhamentos.
    # Até $corporateCredentialTries tentativas. Retorna os compartilhamentos conectados.
    param(
        [Parameter(Mandatory)] [string[]] $Shares,
        [Parameter(Mandatory)] [string] $DomainPrefix
    )
    for ($attempt = 1; $attempt -le $corporateCredentialTries; $attempt++) {
        $credential = Get-Credential -UserName "$DomainPrefix\" `
            -Message ("Credencial do domínio para acessar os instaladores ({0}). Tentativa {1} de {2}." -f ($Shares -join ', '), $attempt, $corporateCredentialTries)
        if ($null -eq $credential) {
            Write-CorporateStatus 'AVISO: a caixa de credencial foi cancelada.' -Level WARN
            continue
        }

        $connected = @()
        try {
            foreach ($share in $Shares) {
                New-SmbMapping -RemotePath $share -UserName $credential.UserName `
                    -Password $credential.GetNetworkCredential().Password -Persistent $false -ErrorAction Stop | Out-Null
                $connected += $share
                if (-not (Test-Path -LiteralPath $share)) {
                    throw "sem acesso a $share"
                }
            }
            Write-CorporateStatus ('Conectado aos compartilhamentos como {0}: {1}.' -f $credential.UserName, ($Shares -join ', '))
            return , $connected
        }
        catch {
            Write-CorporateStatus ('AVISO: não foi possível conectar com a credencial informada ({0}): {1}' -f $credential.UserName, $_.Exception.Message) -Level WARN
            Disconnect-CorporateShare -Shares $connected
        }
    }
    throw "Não foi possível acessar os compartilhamentos após $corporateCredentialTries tentativas."
}

function Disconnect-CorporateShare {
    param([AllowEmptyCollection()] [string[]] $Shares = @())
    foreach ($share in $Shares) {
        Remove-SmbMapping -RemotePath $share -Force -UpdateProfile -ErrorAction SilentlyContinue
        Write-CorporateDetail "Conexão removida: $share"
    }
}

function Confirm-CorporateLicense {
    # Verificação manual da licença do antivírus no portal WithSecure.
    param([Parameter(Mandatory)] $Item)
    Write-Host ''
    Write-Host "  Antes de instalar $($Item.name):" -ForegroundColor Yellow
    Write-Host '  verifique no portal WithSecure Elements se há licença disponível para esta máquina.' -ForegroundColor Yellow
    while ($true) {
        $answer = (Read-Host '  Há licença disponível? (S/N)').Trim().ToUpperInvariant()
        if ($answer -in 'S', 'SIM') { return $true }
        if ($answer -in 'N', 'NAO', 'NÃO') { return $false }
    }
}

function New-CorporateShortcut {
    param(
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Target
    )
    if (-not (Test-Path -LiteralPath $Target)) {
        throw "destino do atalho não encontrado: $Target"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $shortcutPath = Join-Path $Destination "$Name.lnk"
    $shell = New-Object -ComObject 'WScript.Shell'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $Target
    $shortcut.WorkingDirectory = Split-Path -Parent $Target
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw "atalho não foi criado: $shortcutPath"
    }
}

function Get-CorporateProcessTreeId {
    # Id do processo e de todos os seus descendentes (instaladores que abrem outros processos).
    param([Parameter(Mandatory)] [int] $ProcessId)
    $processes = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId)
    $ids = [System.Collections.Generic.List[int]]::new()
    $ids.Add($ProcessId)
    for ($index = 0; $index -lt $ids.Count; $index++) {
        foreach ($child in $processes | Where-Object { $_.ParentProcessId -eq $ids[$index] }) {
            if (-not $ids.Contains([int] $child.ProcessId)) { $ids.Add([int] $child.ProcessId) }
        }
    }
    return , $ids.ToArray()
}

function Add-CorporateWindowMethod {
    # Funções do Windows usadas para clicar em botões e preencher campos de janelas antigas (Win32).
    if (-not ('WorkstationProvisioning.CorporateWindow' -as [type])) {
        Add-Type -Namespace 'WorkstationProvisioning' -Name 'CorporateWindow' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);
'@
    }
}

function Set-CorporateText {
    # Preenche o campo de texto da janela (ex.: a pasta de instalação do BDE). Pelo UI Automation, se disponível;
    # senão, envia WM_SETTEXT ao campo.
    param(
        [Parameter(Mandatory)] [object[]] $Elements,
        [Parameter(Mandatory)] [string] $Text
    )
    $field = $Elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -or $_.Current.ClassName -match '(?i)edit'
    } | Select-Object -First 1
    if ($null -eq $field) {
        throw 'campo de texto não encontrado na janela'
    }
    $pattern = $null
    if ($field.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $pattern) -and -not $pattern.Current.IsReadOnly) {
        $pattern.SetValue($Text)
        return
    }
    $handle = [IntPtr] $field.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) {
        throw 'o campo de texto não pode ser preenchido'
    }
    Add-CorporateWindowMethod
    $wmSetText = 0x000C
    [void] [WorkstationProvisioning.CorporateWindow]::SendMessage($handle, $wmSetText, [IntPtr]::Zero, $Text)
}

function Invoke-CorporateButton {
    # Clica no botão: pelo UI Automation, se disponível; senão, envia BM_CLICK à janela do botão.
    param([Parameter(Mandatory)] $Element)
    $pattern = $null
    $buttonName = $Element.Current.Name
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref] $pattern)) {
        try {
            $pattern.Invoke()
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            # O clique fechou a janela antes de o UI Automation terminar: o botão foi clicado.
            Write-CorporateDetail "A janela fechou durante o clique em '$buttonName'."
        }
        return
    }
    $handle = [IntPtr] $Element.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) {
        throw "o botão '$($Element.Current.Name)' não pode ser clicado"
    }
    Add-CorporateWindowMethod
    $bmClick = 0x00F5

    [void] [WorkstationProvisioning.CorporateWindow]::PostMessage($handle, $bmClick, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-CorporateButtonName {
    # Nomes aceitos para o botão da regra (o instalador pode estar em inglês e o Windows em português).
    param([Parameter(Mandatory)] [string] $Button)
    $aliases = $corporateButtonAliases[$Button.ToUpperInvariant()]
    if ($aliases) { return $aliases }
    return @($Button)
}

function Invoke-CorporatePromptAnswer {
    # Procura, nas janelas do instalador e dos processos abertos por ele, uma janela cujo texto combine com uma
    # das regras de 'prompts' do item, preenche o campo de texto (setText, opcional) e clica no botão da regra.
    # Só toca em janelas desses processos.
    # Retorna a regra respondida, ou $null.
    param(
        [Parameter(Mandatory)] [int] $ProcessId,
        [Parameter(Mandatory)] [object[]] $Prompts,
        [string] $ItemName = 'Instalador'
    )
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $ids = Get-CorporateProcessTreeId -ProcessId $ProcessId
    $automation = [System.Windows.Automation.AutomationElement]
    $anyElement = [System.Windows.Automation.Condition]::TrueCondition

    $windows = $automation::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $anyElement)
    foreach ($window in $windows) {
        if ($window.Current.ProcessId -notin $ids) { continue }
        # O tipo dos controles varia (Text/Button ou Pane, conforme a janela): a busca é pelo nome.
        $elements = @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $anyElement))
        $text = (@($window.Current.Name) + @($elements | ForEach-Object { $_.Current.Name }) | Where-Object { $_ }) -join ' '

        foreach ($prompt in $Prompts) {
            if ($text -notmatch $prompt.text) { continue }
            $names = Get-CorporateButtonName -Button $prompt.button
            $button = $elements | Where-Object { $_.Current.Name -and $_.Current.Name.Replace('&', '').Trim() -in $names } |
                Select-Object -First 1
            if ($null -eq $button) { continue }
            if (-not [string]::IsNullOrWhiteSpace($prompt.setText)) {
                # Ex.: digita a pasta padrão da empresa antes do OK.
                Set-CorporateText -Elements $elements -Text $prompt.setText
                Write-CorporateDetail ("{0}: campo preenchido com '{1}'." -f $ItemName, $prompt.setText)
            }
            Invoke-CorporateButton -Element $button
            Write-CorporateStatus ("{0}: janela do instalador respondida com '{1}': {2}" -f $ItemName, $prompt.button, $text)
            return $prompt
        }
    }
    return $null
}

function Wait-CorporateProcess {
    # Aguarda o instalador terminar, respondendo sozinho às janelas previstas em -Prompts (regras do item).
    # Retorna $true se alguma janela respondida era um pedido de reinício (regra com restartPending).
    param(
        [Parameter(Mandatory)] $Process,   # System.Diagnostics.Process
        [object[]] $Prompts = @(),
        [string] $ItemName = 'Instalador',
        [int] $IntervalMilliseconds = 2000
    )
    $isRestartPending = $false
    while (-not $Process.WaitForExit($IntervalMilliseconds)) {
        if ($Prompts.Count -eq 0) { continue }
        try {
            $answered = Invoke-CorporatePromptAnswer -ProcessId $Process.Id -Prompts $Prompts -ItemName $ItemName
            if ($null -ne $answered -and $answered.restartPending) { $isRestartPending = $true }
        }
        catch {
            Write-CorporateDetail "Não foi possível verificar as janelas do instalador: $($_.Exception.Message)"
        }
    }
    $Process.WaitForExit()
    return $isRestartPending
}

function Start-CorporateProcess {
    # Inicia o instalador SEM passar pelo Shell (UseShellExecute = false). Pelo Shell, o Windows mostra
    # "Abrir Arquivo - Aviso de Segurança" para executáveis em pastas de rede fora da zona Intranet
    # (aconteceu com o WithSecure em \\marketing) e espera o clique do técnico.
    # O provisionamento já roda como administrador; o instalador herda essa permissão.
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string] $Arguments = ''
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName         = $FilePath
    $startInfo.Arguments        = $Arguments
    $startInfo.UseShellExecute  = $false
    $startInfo.WorkingDirectory = Split-Path -Parent $FilePath
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Assert-CorporateFileHash {
    # Com 'sha256' no item, confere o instalador antes de executar: um arquivo trocado ou corrompido não roda.
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not $Item.sha256) { return }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne ([string] $Item.sha256).ToUpperInvariant()) {
        throw "o SHA-256 do instalador não confere (esperado $($Item.sha256), encontrado $actual): $Path"
    }
    Write-CorporateDetail "SHA-256 conferido: $Path"
}

function Resolve-CorporateDestination {
    # Destino da cópia: 'destination' fixo ou o caminho gravado no registro ('destinationRegistry'),
    # ex.: o IDAPI32.CFG vai para onde o BDE foi instalado (Borland\Database Engine\CONFIGFILE01).
    param([Parameter(Mandatory)] $Item)
    if ($null -eq $Item.destinationRegistry) {
        return $Item.destination
    }
    $key   = $Item.destinationRegistry.key
    $value = $Item.destinationRegistry.value
    $properties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $path = if ($properties) { [string] $properties.$value } else { '' }
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "o registro não indica o destino ($key, valor $value). O programa foi instalado?"
    }
    return $path
}
function Invoke-CorporateItem {
    # Executa o item conforme o tipo. Lança erro com o motivo se falhar.
    # Retorna $true se o instalador pediu reinício e ele foi adiado (regra de 'prompts' com restartPending).
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [Parameter(Mandatory)] [string] $WorkDir
    )
    switch ($Item.type) {
        'odt' {
            # O setup.exe é copiado para a pasta de trabalho e executado de lá: ao lado do setup.exe do servidor
            # existe uma cópia antiga do Office (Office\Data\16.0.11425, de 2019), que o ODT usaria no lugar
            # do download da Microsoft. Fora dessa pasta, o ODT baixa a versão atual.
            $setup  = Resolve-CorporateItemPath -Item $Item
            $xml    = Join-Path $ConfigDir $Item.odtConfig
            if (-not (Test-Path -LiteralPath $xml)) { throw "configuração do ODT não encontrada: $xml" }
            $odtDir = Join-Path $WorkDir 'odt'
            New-Item -ItemType Directory -Force -Path $odtDir | Out-Null
            $localSetup = Join-Path $odtDir 'setup.exe'
            $localXml   = Join-Path $odtDir 'configuration.xml'
            Copy-Item -LiteralPath $setup -Destination $localSetup -Force
            Copy-Item -LiteralPath $xml -Destination $localXml -Force
            Write-CorporateStatus "$($Item.name): instalando pelo ODT (download da Microsoft; pode levar de 15 a 40 minutos)..."
            $process = Start-Process -FilePath $localSetup -ArgumentList ('/configure "{0}"' -f $localXml) `
                -WorkingDirectory $odtDir -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -ne 0) { throw "o ODT terminou com exit code $($process.ExitCode)" }
        }
        'exe' {
            $installer = Resolve-CorporateItemPath -Item $Item
            Assert-CorporateFileHash -Item $Item -Path $installer
            Write-CorporateStatus "$($Item.name): instalando..."
            Write-CorporateDetail "Executando: $installer $($Item.arguments)"
            $process = Start-CorporateProcess -FilePath $installer -Arguments ([string] $Item.arguments)
            $isRestartPending = Wait-CorporateProcess -Process $process -Prompts @($Item.prompts | Where-Object { $_ }) -ItemName $Item.name
            if ($process.ExitCode -notin $corporateExeSuccessCodes) { throw "o instalador terminou com exit code $($process.ExitCode)" }
            if ($isRestartPending) {
                Write-CorporateStatus "$($Item.name): o instalador pediu para reiniciar; o reinício foi adiado para o final." -Level WARN
            }
            return $isRestartPending
        }
        'msi' {
            # msiexec silencioso, com log detalhado ao lado do corporate-software.log. 'arguments' acrescenta
            # propriedades do pacote (ex.: aceite da licença do ODBC Driver 11).
            $package = Resolve-CorporateItemPath -Item $Item
            Assert-CorporateFileHash -Item $Item -Path $package
            $msiLogDir = if ($script:corporateLogFile) { Split-Path -Parent $script:corporateLogFile } else { $WorkDir }
            New-Item -ItemType Directory -Force -Path $msiLogDir | Out-Null
            $msiLog = Join-Path $msiLogDir ('msi-{0}.log' -f $Item.id)
            $msiArguments = ('/i "{0}" /qn /norestart /l*v "{1}" {2}' -f $package, $msiLog, $Item.arguments).Trim()
            Write-CorporateStatus "$($Item.name): instalando (log em $msiLog)..."
            $process = Start-CorporateProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -Arguments $msiArguments
            $isRestartPending = Wait-CorporateProcess -Process $process -Prompts @($Item.prompts | Where-Object { $_ }) -ItemName $Item.name
            if ($process.ExitCode -notin $corporateExeSuccessCodes) {
                throw "o msiexec terminou com exit code $($process.ExitCode) (detalhes em $msiLog)"
            }
            # 3010 = instalado, mas o Windows precisa reiniciar para concluir.
            return ($isRestartPending -or $process.ExitCode -eq 3010)
        }
        'bat' {
            # A entrada vem de um arquivo vazio: os "pause" do .bat passam sozinhos, sem esperar uma tecla.
            $bat = Resolve-CorporateItemPath -Item $Item
            New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
            $emptyInput = Join-Path $WorkDir 'empty-input.txt'
            [IO.File]::WriteAllText($emptyInput, '')
            # Saída do .bat ao lado do corporate-software.log (ou na pasta de trabalho, se o log não foi definido).
            $batLogDir = if ($script:corporateLogFile) { Split-Path -Parent $script:corporateLogFile } else { $WorkDir }
            $batLog = Join-Path $batLogDir ('{0}.log' -f $Item.id)
            Write-CorporateStatus "$($Item.name): executando $bat (saída em $batLog)..."
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f $bat) -Wait -PassThru `
                -WorkingDirectory $env:SystemRoot -RedirectStandardInput $emptyInput `
                -RedirectStandardOutput $batLog -RedirectStandardError "$batLog.err"
            if ($process.ExitCode -ne 0) { throw "o .bat terminou com exit code $($process.ExitCode) (detalhes em $batLog)" }
        }
        'copy-folder' {
            if (-not (Test-Path -LiteralPath $Item.source)) { throw "origem não encontrada: $($Item.source)" }
            Write-CorporateStatus "$($Item.name): copiando $($Item.source) para $($Item.destination)..."
            $output = & robocopy.exe $Item.source $Item.destination /E /R:2 /W:5 /NP /NFL /NDL /NJH 2>&1
            # Robocopy: 0 a 7 = sucesso (com ou sem arquivos copiados); 8 ou mais = falha.
            if ($LASTEXITCODE -ge 8) { throw "robocopy terminou com código $LASTEXITCODE`: $(($output | Select-Object -Last 3) -join ' ')" }
        }
        'copy-file' {
            if (-not (Test-Path -LiteralPath $Item.source)) { throw "origem não encontrada: $($Item.source)" }
            $destination = Resolve-CorporateDestination -Item $Item
            Write-CorporateStatus "$($Item.name): copiando para $destination..."
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $Item.source -Destination $destination -Force
        }
        'registry' {
            # Grava (ou regrava) os valores na chave do registro. Ex.: o túnel da VPN no FortiClient.
            Write-CorporateStatus "$($Item.name): configurando $($Item.key)..."
            if (-not (Test-Path -LiteralPath $Item.key)) {
                New-Item -Path $Item.key -Force | Out-Null
            }
            foreach ($entry in @($Item.values)) {
                New-ItemProperty -LiteralPath $Item.key -Name $entry.name -Value $entry.value -PropertyType $entry.kind -Force | Out-Null
            }
        }
        'shortcuts' {
            Write-CorporateStatus "$($Item.name): criando atalhos em $($Item.destination)..."
            foreach ($shortcut in @($Item.shortcuts)) {
                New-CorporateShortcut -Destination $Item.destination -Name $shortcut.name -Target $shortcut.target
            }
        }
    }
}

function Install-CorporateItem {
    # Executa um item e retorna o resultado (Name, Required, Status, Message). Nunca lança erro.
    # Status: Installed, AlreadyInstalled, Skipped ou Failed. IsRestartPending: o instalador pediu reinício (adiado).
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [Parameter(Mandatory)] [string] $WorkDir
    )
    $result = [pscustomobject] @{ Name = $Item.name; Required = [bool] $Item.required; Status = ''; Message = ''; IsRestartPending = $false }

    try {
        if (Test-CorporateItemInstalled -Item $Item) {
            $result.Status = 'AlreadyInstalled'
            Write-CorporateStatus "$($Item.name): já está instalado."
            return $result
        }

        if ($Item.confirmLicense -and -not (Confirm-CorporateLicense -Item $Item)) {
            $result.Status  = 'Skipped'
            $result.Message = 'sem licença disponível no WithSecure (instale depois de liberar a licença)'
            Write-CorporateStatus "AVISO: $($Item.name) não instalado: $($result.Message)." -Level WARN
            return $result
        }

        $result.IsRestartPending = [bool] (Invoke-CorporateItem -Item $Item -ConfigDir $ConfigDir -WorkDir $WorkDir)

        if ($null -ne $Item.detect -and -not (Test-CorporateItemInstalled -Item $Item)) {
            throw 'terminou sem erro, mas não aparece como instalado'
        }
        $result.Status = 'Installed'
        Write-CorporateStatus "$($Item.name): concluído."
    }
    catch {
        $result.Status  = 'Failed'
        $result.Message = $_.Exception.Message
        Write-CorporateDetail "Falha em $($Item.name): $($result.Message)"
    }
    return $result
}

function Show-CorporateSummary {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results)
    Write-CorporateStatus 'Resumo dos softwares corporativos:'
    foreach ($result in $Results) {
        switch ($result.Status) {
            'Installed'        { Write-CorporateStatus ('  [OK]         {0}' -f $result.Name) }
            'AlreadyInstalled' { Write-CorporateStatus ('  [JÁ HAVIA]   {0}' -f $result.Name) }
            'Skipped'          { Write-CorporateStatus ('  [PULADO]     {0} - {1}' -f $result.Name, $result.Message) -Level WARN }
            default            { Write-CorporateStatus ('  [FALHA]      {0} - {1}' -f $result.Name, $result.Message) -Level ERROR }
        }
    }
}

function Install-CorporateSoftware {
    # Executa a etapa. Retorna $true se nenhum item obrigatório falhou (itens pulados não contam como falha).
    param(
        [Parameter(Mandatory)] [string] $ConfigFile,
        [Parameter(Mandatory)] [string] $LogFile,
        [Parameter(Mandatory)] [string] $WorkDir,
        [Parameter(Mandatory)] [string] $DomainPrefix
    )
    $script:corporateLogFile = $LogFile
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
    Write-CorporateDetail '==== Início da etapa de softwares corporativos ===='

    $config    = Read-CorporateConfig -Path $ConfigFile
    $configDir = Split-Path -Parent $ConfigFile
    Write-CorporateStatus ('Itens: {0}' -f (($config.Items | ForEach-Object { $_.name }) -join ', '))

    $connected = @()
    $results   = @()
    try {
        $connected = Connect-CorporateShare -Shares $config.Shares -DomainPrefix $DomainPrefix
        # Todos os itens são tentados, mesmo que um falhe, para o técnico ver de uma vez tudo o que deu errado.
        $results = @(foreach ($item in $config.Items) {
            Install-CorporateItem -Item $item -ConfigDir $configDir -WorkDir $WorkDir
        })
    }
    finally {
        Disconnect-CorporateShare -Shares $connected
    }

    Show-CorporateSummary -Results $results
    $restartPending = @($results | Where-Object { $_.IsRestartPending })
    if ($restartPending.Count -gt 0) {
        Write-CorporateStatus ('AVISO: reinicie o computador antes de entregá-lo ao usuário ({0} pediu reinício para concluir a instalação).' -f `
            (($restartPending | ForEach-Object { $_.Name }) -join ', ')) -Level WARN
    }
    $failedRequired = @($results | Where-Object { $_.Status -eq 'Failed' -and $_.Required })
    if ($failedRequired.Count -gt 0) {
        Write-CorporateStatus ('ERRO: software(s) obrigatório(s) não instalado(s): {0}. Detalhes em {1}.' -f `
            (($failedRequired | ForEach-Object { $_.Name }) -join ', '), $LogFile) -Level ERROR
        return $false
    }
    return $true
}
