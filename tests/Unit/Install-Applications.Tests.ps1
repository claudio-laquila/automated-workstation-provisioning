# Testes de unidade de scripts\Install-Applications.ps1.
#
# Download (Invoke-WebRequest), assinatura digital (Get-AuthenticodeSignature), execução do instalador
# (Start-Process) e a lista de programas instalados (registro) são SIMULADOS:
# nada é baixado nem instalado de verdade. Os arquivos vão para a pasta temporária do Pester ($TestDrive).
# Requer Pester 5 ou superior (testado com Pester 6.2 no Windows PowerShell 5.1).
#
# Como rodar, a partir da raiz do projeto:
#   Import-Module Pester -MinimumVersion 5.0
#   Invoke-Pester -Path .\tests\Unit\Install-Applications.Tests.ps1 -Output Detailed

Describe 'Install-Applications.ps1' {

    BeforeAll {
        $scriptPath  = Join-Path $PSScriptRoot '..\..\scripts\Install-Applications.ps1'
        $projectApps = Join-Path $PSScriptRoot '..\..\config\apps.json'
        $testRoot    = Join-Path $TestDrive 'root'

        # Carregado por dot-source: só define as funções (guarda de execução).
        . $scriptPath -RootDir $testRoot

        # Aplicativo de teste no mesmo formato do config\apps.json.
        function New-TestApplication {
            param(
                [string] $Id          = 'chrome',
                [string] $Name        = 'Google Chrome',
                [string] $Type        = 'msi',
                [string] $Url         = 'https://exemplo.test/app.msi',
                [string] $FileName    = 'app.msi',
                [string] $Arguments   = '/qn /norestart',
                [string] $Sha256      = '',
                [string] $Signer      = 'Google LLC',
                [string] $DisplayName = 'Google Chrome',
                $Required             = $true
            )
            return [pscustomobject] @{
                id = $Id; name = $Name; type = $Type; url = $Url; fileName = $FileName; arguments = $Arguments
                sha256 = $Sha256; signer = $Signer; displayName = $DisplayName; required = $Required
            }
        }

        function Set-AppsConfig {
            param([object[]] $Applications)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configFile) | Out-Null
            @{ applications = @($Applications) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8
        }

        # Arquivo com conteúdo conhecido e o hash SHA-256 dele.
        function New-ContentFile {
            param([string] $Path, [string] $Content)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            [IO.File]::WriteAllText($Path, $Content)
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }

        $downloadedContent = 'instalador baixado do site oficial'
        $downloadedHash    = New-ContentFile -Path (Join-Path $TestDrive 'hash-download.bin') -Content $downloadedContent
        $usbContent        = 'instalador copiado do pendrive'
        $usbHash           = New-ContentFile -Path (Join-Path $TestDrive 'hash-pendrive.bin') -Content $usbContent

        function New-Signature {
            param([string] $Status = 'Valid', [string] $Subject = 'CN=Google LLC, O=Google LLC, L=Mountain View, C=US')
            return [pscustomobject] @{ Status = $Status; SignerCertificate = [pscustomobject] @{ Subject = $Subject } }
        }
    }

    BeforeEach {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Mock Write-Status { }
        Mock Start-Sleep { }
    }

    Context 'Carregamento do script' {

        It 'carregado por dot-source, define as funções e não executa a etapa' {
            $guardRoot = Join-Path $TestDrive 'guarda'

            . $scriptPath -RootDir $guardRoot

            Get-Command Install-Applications -CommandType Function | Should -Not -BeNullOrEmpty
            $guardRoot | Should -Not -Exist
        }

        It 'usa os caminhos dentro de -RootDir' {
            $configFile    | Should -Be (Join-Path $testRoot 'config\apps.json')
            $installersDir | Should -Be (Join-Path $testRoot 'installers')
            $logFile       | Should -Be (Join-Path $testRoot 'Logs\applications.log')
        }
    }

    Context 'Read-ApplicationList: config\apps.json' {

        It 'aceita o config\apps.json real do projeto (Chrome, 7-Zip e VLC, todos obrigatórios)' {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configFile) | Out-Null
            Copy-Item -LiteralPath $projectApps -Destination $configFile -Force

            $applications = Read-ApplicationList

            ($applications | ForEach-Object { $_.id }) -join ',' | Should -Be 'chrome,7zip,vlc'
            $applications | ForEach-Object { $_.required | Should -BeTrue }
            $applications | ForEach-Object { $_.type | Should -Be 'msi' }
            ($applications | Where-Object id -eq 'chrome').signer | Should -Be 'Google LLC'
            ($applications | Where-Object id -eq '7zip').sha256 | Should -Match '^[0-9A-F]{64}$'
            ($applications | Where-Object id -eq 'vlc').sha256  | Should -Match '^[0-9A-F]{64}$'
        }

        It 'falha se o arquivo não existir' {
            if (Test-Path -LiteralPath $configFile) { Remove-Item -LiteralPath $configFile }

            { Read-ApplicationList } | Should -Throw '*Lista de aplicativos não encontrada*'
        }

        It 'falha se o JSON for inválido' {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configFile) | Out-Null
            Set-Content -LiteralPath $configFile -Value '{ isto não é json'

            { Read-ApplicationList } | Should -Throw '*inválida (JSON)*'
        }

        It 'falha se não houver aplicativos' {
            Set-AppsConfig -Applications @()

            { Read-ApplicationList } | Should -Throw '*Nenhum aplicativo*'
        }

        It 'falha se faltar um campo obrigatório' {
            $application = New-TestApplication
            $application.fileName = ''
            Set-AppsConfig -Applications @($application)

            { Read-ApplicationList } | Should -Throw "*sem o campo 'fileName'*"
        }

        It 'recusa endereço sem HTTPS' {
            Set-AppsConfig -Applications @(New-TestApplication -Url 'http://exemplo.test/app.msi')

            { Read-ApplicationList } | Should -Throw '*precisa usar HTTPS*'
        }

        It 'exige sha256 e/ou signer para validar o instalador' {
            Set-AppsConfig -Applications @(New-TestApplication -Sha256 '' -Signer '')

            { Read-ApplicationList } | Should -Throw "*informe 'sha256' e/ou 'signer'*"
        }

        It 'aceita só os tipos msi e exe' {
            Set-AppsConfig -Applications @(New-TestApplication -Type 'zip')

            { Read-ApplicationList } | Should -Throw "*tipo 'zip' inválido*"
        }

        It 'exige argumentos de instalação silenciosa para EXE' {
            Set-AppsConfig -Applications @(New-TestApplication -Type 'exe' -Arguments '')

            { Read-ApplicationList } | Should -Throw '*EXE exige*'
        }

        It "exige 'required' verdadeiro ou falso" {
            Set-AppsConfig -Applications @(New-TestApplication -Required 'sim')

            { Read-ApplicationList } | Should -Throw "*'required' precisa ser true ou false*"
        }
    }

    Context 'Test-ApplicationInstalled' {

        It 'encontra o programa pelo nome com curinga (7-Zip*)' {
            Mock Get-InstalledProgramName { , @('Microsoft Edge', '7-Zip 26.04 (x64 edition)') }

            Test-ApplicationInstalled -Application (New-TestApplication -DisplayName '7-Zip*') | Should -BeTrue
        }

        It 'não considera instalado um programa com nome parecido' {
            Mock Get-InstalledProgramName { , @('Google Chrome Beta') }

            Test-ApplicationInstalled -Application (New-TestApplication -DisplayName 'Google Chrome') | Should -BeFalse
        }

        It 'retorna $false sem nenhum programa instalado' {
            Mock Get-InstalledProgramName { , @() }

            Test-ApplicationInstalled -Application (New-TestApplication) | Should -BeFalse
        }
    }

    Context 'Assert-InstallerFile: validação do instalador' {

        BeforeAll {
            $file = Join-Path $TestDrive 'validar.msi'
            $fileHash = New-ContentFile -Path $file -Content $downloadedContent
        }

        It 'aceita o arquivo com o hash SHA-256 esperado (inclusive em minúsculas)' {
            { Assert-InstallerFile -Application (New-TestApplication -Sha256 $fileHash.ToLower() -Signer '') -Path $file } |
                Should -Not -Throw
        }

        It 'recusa o arquivo com hash diferente' {
            { Assert-InstallerFile -Application (New-TestApplication -Sha256 ('0' * 64) -Signer '') -Path $file } |
                Should -Throw '*hash SHA-256 diferente*'
        }

        It 'aceita a assinatura válida do fabricante esperado' {
            Mock Get-AuthenticodeSignature { New-Signature }

            { Assert-InstallerFile -Application (New-TestApplication -Signer 'Google LLC') -Path $file } | Should -Not -Throw
        }

        It 'recusa arquivo sem assinatura válida' {
            Mock Get-AuthenticodeSignature { New-Signature -Status 'NotSigned' }

            { Assert-InstallerFile -Application (New-TestApplication -Signer 'Google LLC') -Path $file } |
                Should -Throw '*assinatura digital inválida (NotSigned)*'
        }

        It 'recusa arquivo assinado por outra empresa' {
            Mock Get-AuthenticodeSignature { New-Signature -Subject 'CN=Outra Empresa Ltda, O=Outra Empresa Ltda' }

            { Assert-InstallerFile -Application (New-TestApplication -Signer 'Google LLC') -Path $file } |
                Should -Throw "*assinado por 'Outra Empresa Ltda', esperado 'Google LLC'*"
        }

        It 'confere hash e assinatura quando os dois estão configurados' {
            Mock Get-AuthenticodeSignature { New-Signature -Subject 'CN=Outra Empresa Ltda' }

            { Assert-InstallerFile -Application (New-TestApplication -Sha256 $fileHash -Signer 'Google LLC') -Path $file } |
                Should -Throw '*assinado por*'
        }
    }

    Context 'Save-InstallerFile: download' {

        It 'recusa endereço sem HTTPS, sem tentar baixar' {
            Mock Invoke-WebRequest { }

            { Save-InstallerFile -Url 'http://exemplo.test/a.msi' -Path (Join-Path $TestDrive 'a.msi') } | Should -Throw '*não usa HTTPS*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'tenta de novo após falhas, aguardando 30 s entre as tentativas' {
            $calls = [ref] 0
            Mock Invoke-WebRequest {
                $calls.Value++
                if ($calls.Value -lt 3) { throw 'falha de rede simulada' }
                [IO.File]::WriteAllText($OutFile, 'ok')
            }

            Save-InstallerFile -Url 'https://exemplo.test/a.msi' -Path (Join-Path $TestDrive 'retry\a.msi')

            Join-Path $TestDrive 'retry\a.msi' | Should -Exist
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 30 }
        }

        It 'desiste após 3 tentativas e identifica a inspeção SSL do firewall' {
            Mock Invoke-WebRequest { throw 'Não foi possível estabelecer relação de confiança para o canal seguro de SSL/TLS.' }

            { Save-InstallerFile -Url 'https://exemplo.test/a.msi' -Path (Join-Path $TestDrive 'a.msi') } |
                Should -Throw '*provável inspeção SSL do firewall*'
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }
    }

    Context 'Get-ApplicationInstaller: download com reserva no pendrive' {

        BeforeEach {
            $application = New-TestApplication -Id 'app' -FileName 'app.msi' -Signer '' -Sha256 $downloadedHash
            $usbFile = Join-Path $installersDir 'app\app.msi'
            if (Test-Path -LiteralPath $usbFile) { Remove-Item -LiteralPath $usbFile }
        }

        It 'usa o download oficial quando ele é válido' {
            Mock Invoke-WebRequest { [IO.File]::WriteAllText($OutFile, $downloadedContent) }

            $installer = Get-ApplicationInstaller -Application $application

            $installer.Source      | Should -Be 'download'
            $installer.IsTemporary | Should -BeTrue
            $installer.Path        | Should -Be (Join-Path $downloadDir 'app.msi')
        }

        It 'usa a cópia do pendrive quando o download falha, avisando na tela' {
            Mock Invoke-WebRequest { throw 'falha de rede simulada' }
            $application.sha256 = New-ContentFile -Path $usbFile -Content $usbContent

            $installer = Get-ApplicationInstaller -Application $application

            $installer.Source      | Should -Be 'pendrive'
            $installer.IsTemporary | Should -BeFalse
            $installer.Path        | Should -Be $usbFile
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'AVISO: *download indisponível*pendrive*' }
        }

        It 'usa o pendrive e apaga o download quando o arquivo baixado é inválido' {
            Mock Invoke-WebRequest { [IO.File]::WriteAllText($OutFile, 'conteúdo adulterado') }
            $application.sha256 = New-ContentFile -Path $usbFile -Content $usbContent

            $installer = Get-ApplicationInstaller -Application $application

            $installer.Source | Should -Be 'pendrive'
            Join-Path $downloadDir 'app.msi' | Should -Not -Exist
        }

        It 'falha informando os dois motivos quando não há download nem cópia no pendrive' {
            Mock Invoke-WebRequest { throw 'falha de rede simulada' }

            { Get-ApplicationInstaller -Application $application } |
                Should -Throw '*download: falha de rede simulada*pendrive: arquivo não encontrado*'
        }

        It 'falha quando a cópia do pendrive também é inválida' {
            Mock Invoke-WebRequest { throw 'falha de rede simulada' }
            [void] (New-ContentFile -Path $usbFile -Content 'versão diferente da configurada')

            { Get-ApplicationInstaller -Application $application } | Should -Throw '*pendrive: hash SHA-256 diferente*'
        }
    }

    Context 'Invoke-ApplicationInstaller: execução do instalador' {

        It 'executa MSI com msiexec em modo silencioso e grava o log da instalação' {
            Mock Start-Process { [pscustomobject] @{ ExitCode = 0 } }

            Invoke-ApplicationInstaller -Application (New-TestApplication -Id 'chrome') -InstallerPath 'C:\tmp\app.msi' | Should -Be 0

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and
                $ArgumentList -like '/i "C:\tmp\app.msi" /qn /norestart /l`*v "*msi-chrome.log"' -and
                $Wait -and $PassThru
            }
        }

        It 'executa EXE com os argumentos configurados' {
            Mock Start-Process { [pscustomobject] @{ ExitCode = 0 } }
            $application = New-TestApplication -Type 'exe' -Arguments '/S'

            [void] (Invoke-ApplicationInstaller -Application $application -InstallerPath 'C:\tmp\setup.exe')

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\tmp\setup.exe' -and $ArgumentList -eq '/S' }
        }

        It 'aguarda e tenta de novo quando outra instalação está em andamento (1618)' {
            $calls = [ref] 0
            Mock Start-Process {
                $calls.Value++
                [pscustomobject] @{ ExitCode = $(if ($calls.Value -eq 1) { 1618 } else { 0 }) }
            }

            Invoke-ApplicationInstaller -Application (New-TestApplication) -InstallerPath 'C:\tmp\app.msi' | Should -Be 0
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'AVISO: *outra instalação*' }
        }

        It 'desiste quando a outra instalação não termina' {
            Mock Start-Process { [pscustomobject] @{ ExitCode = 1618 } }

            { Invoke-ApplicationInstaller -Application (New-TestApplication) -InstallerPath 'C:\tmp\app.msi' } |
                Should -Throw '*continuou em andamento (exit code 1618)*'
        }
    }

    Context 'Install-Application: um aplicativo' {

        BeforeEach {
            $installedNames = [System.Collections.Generic.List[string]]::new()
            Mock Get-InstalledProgramName { , @($installedNames) }
            Mock Invoke-WebRequest { [IO.File]::WriteAllText($OutFile, $downloadedContent) }
            Mock Get-AuthenticodeSignature { New-Signature }
            Mock Start-Process {
                $installedNames.Add('Google Chrome')
                [pscustomobject] @{ ExitCode = 0 }
            }
            $application = New-TestApplication
        }

        It 'pula o aplicativo que já está instalado, sem baixar' {
            $installedNames.Add('Google Chrome')

            $result = Install-Application -Application $application

            $result.Status | Should -Be 'AlreadyInstalled'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'baixa, valida, instala e apaga o instalador baixado' {
            $result = Install-Application -Application $application

            $result.Status | Should -Be 'Installed'
            $result.Source | Should -Be 'download'
            Join-Path $downloadDir 'app.msi' | Should -Not -Exist
        }

        It 'registra reinicialização pendente quando o MSI retorna 3010' {
            Mock Start-Process { $installedNames.Add('Google Chrome'); [pscustomobject] @{ ExitCode = 3010 } }

            $result = Install-Application -Application $application

            $result.Status  | Should -Be 'Installed'
            $result.Message | Should -Be 'reinicialização pendente'
        }

        It 'marca falha quando o instalador retorna erro (1603)' {
            Mock Start-Process { [pscustomobject] @{ ExitCode = 1603 } }

            $result = Install-Application -Application $application

            $result.Status  | Should -Be 'Failed'
            $result.Message | Should -BeLike '*exit code 1603*'
        }

        It 'marca falha quando o instalador termina sem erro mas o programa não aparece instalado' {
            Mock Start-Process { [pscustomobject] @{ ExitCode = 0 } }

            $result = Install-Application -Application $application

            $result.Status  | Should -Be 'Failed'
            $result.Message | Should -BeLike '*não aparece como instalado*'
        }

        It 'não lança erro quando não há instalador disponível: devolve a falha no resultado' {
            Mock Invoke-WebRequest { throw 'falha de rede simulada' }

            { Install-Application -Application $application } | Should -Not -Throw
            (Install-Application -Application $application).Status | Should -Be 'Failed'
        }

        It 'não apaga o instalador do pendrive depois de instalar' {
            Mock Invoke-WebRequest { throw 'falha de rede simulada' }
            $usbFile = Join-Path $installersDir 'chrome\app.msi'
            [void] (New-ContentFile -Path $usbFile -Content $usbContent)

            $result = Install-Application -Application $application

            $result.Source | Should -Be 'pendrive'
            $usbFile | Should -Exist
        }
    }

    Context 'Install-Applications: etapa completa' {

        BeforeEach {
            $installedNames = [System.Collections.Generic.List[string]]::new()
            Mock Get-InstalledProgramName { , @($installedNames) }
            Mock Get-AuthenticodeSignature { New-Signature }
            # Instala com sucesso o programa do arquivo informado, exceto o "vlc" (falha 1603).
            Mock Start-Process {
                if ($ArgumentList -like '*vlc.msi*') { return [pscustomobject] @{ ExitCode = 1603 } }
                if ($ArgumentList -like '*7zip.msi*') { $installedNames.Add('7-Zip 26.04 (x64 edition)') }
                if ($ArgumentList -like '*chrome.msi*') { $installedNames.Add('Google Chrome') }
                [pscustomobject] @{ ExitCode = 0 }
            }
            Mock Invoke-WebRequest { [IO.File]::WriteAllText($OutFile, $downloadedContent) }

            $chrome = New-TestApplication -Id 'chrome' -Name 'Google Chrome' -FileName 'chrome.msi' -DisplayName 'Google Chrome'
            $sevenZip = New-TestApplication -Id '7zip' -Name '7-Zip' -FileName '7zip.msi' -Signer '' -Sha256 $downloadedHash -DisplayName '7-Zip*'
            $vlc = New-TestApplication -Id 'vlc' -Name 'VLC media player' -FileName 'vlc.msi' -Signer '' -Sha256 $downloadedHash -DisplayName 'VLC media player*'
        }

        It 'retorna 0 quando todos os aplicativos são instalados' {
            Set-AppsConfig -Applications @($chrome, $sevenZip)

            Install-Applications | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*`[OK`]*Google Chrome*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*`[OK`]*7-Zip*' }
        }

        It 'tenta todos mesmo quando um obrigatório falha, mostra a falha e retorna 1' {
            Set-AppsConfig -Applications @($chrome, $vlc, $sevenZip)

            Install-Applications | Should -Be 1

            Should -Invoke Start-Process -Times 3 -Exactly
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*`[FALHA`]*VLC media player - *exit code 1603*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'ERRO: aplicativo(s) obrigatório(s) não instalado(s): VLC media player*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*`[OK`]*7-Zip*' }
        }

        It 'retorna 0 com aviso quando só um aplicativo opcional falha' {
            $vlc.required = $false
            Set-AppsConfig -Applications @($chrome, $vlc)

            Install-Applications | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*`[FALHA`]*VLC media player (opcional)*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'AVISO: aplicativo(s) opcional(is) não instalado(s): VLC media player*' }
        }

        It 'mostra quem já estava instalado' {
            $installedNames.Add('Google Chrome')
            Set-AppsConfig -Applications @($chrome)

            Install-Applications | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*`[JÁ HAVIA`]*Google Chrome*' }
        }

        It 'falha com erro claro quando a lista de aplicativos é inválida' {
            Set-AppsConfig -Applications @()

            { Install-Applications } | Should -Throw '*Nenhum aplicativo*'
        }

        It 'retorna somente o código de saída' {
            Set-AppsConfig -Applications @($chrome)

            $output = @(Install-Applications)

            $output.Count | Should -Be 1
        }
    }
}
