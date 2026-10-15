# Testes de unidade de scripts\Install-WindowsUpdates.ps1.
#
# A API do Windows Update (COM Microsoft.Update.*) é SIMULADA com objetos falsos:
# nenhuma atualização é procurada, baixada ou instalada de verdade.
# Os arquivos (log e contagem de falhas) vão para a pasta temporária do Pester ($TestDrive).
# Requer Pester 5 ou superior (testado com Pester 6.2 no Windows PowerShell 5.1).
#
# Como rodar, a partir da raiz do projeto:
#   Import-Module Pester -MinimumVersion 5.0
#   Invoke-Pester -Path .\tests\Unit\Install-WindowsUpdates.Tests.ps1 -Output Detailed

# Os testes atribuem $SearchOnly, $ExcludeDrivers e $ExcludeOptional para que as funções do script os leiam
# pelo escopo. O analisador não enxerga esse uso e acusaria "variável atribuída e nunca usada".
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Describe 'Install-WindowsUpdates.ps1' {

    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\..\scripts\Install-WindowsUpdates.ps1'
        $testRoot   = Join-Path $TestDrive 'root'
        New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'Logs') | Out-Null

        # Carregado por dot-source: só define as funções (guarda de execução).
        . $scriptPath -RootDir $testRoot

        $previewUpgradeCategory = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'

        # Atualização falsa com o mesmo formato que a API devolve (IUpdate).
        function New-FakeUpdate {
            param(
                [string]   $Id                  = ([guid]::NewGuid().ToString()),
                [string]   $Title               = 'Atualização cumulativa para Windows 11',
                [string]   $Kb                  = '5000001',
                [int]      $Type                = 1,        # 1 = software, 2 = driver
                [bool]     $BrowseOnly          = $false,   # opcional
                [bool]     $CanRequestUserInput = $false,
                [string[]] $CategoryIds         = @(),
                [bool]     $EulaAccepted        = $true,
                [bool]     $IsDownloaded        = $false,
                [int]      $DownloadResultCode  = 2,        # 2 = sucesso
                [int]      $InstallResultCode   = 2,
                [bool]     $RebootRequired      = $false,
                [int]      $InstallThrowsHResult = 0        # <> 0: Install() lança erro COM com esse código
            )
            # ::new() em vez de New-Object: New-Object é simulado em alguns testes.
            $kbIds = [System.Collections.Generic.List[string]]::new()
            if ($Kb) { $kbIds.Add($Kb) }

            $update = [pscustomobject] @{
                Identity             = [pscustomobject] @{ UpdateID = $Id }
                Title                = $Title
                Type                 = $Type
                BrowseOnly           = $BrowseOnly
                InstallationBehavior = [pscustomobject] @{ CanRequestUserInput = $CanRequestUserInput }
                Categories           = @($CategoryIds | ForEach-Object { [pscustomobject] @{ CategoryID = $_ } })
                KBArticleIDs         = $kbIds
                EulaAccepted         = $EulaAccepted
                IsDownloaded         = $IsDownloaded
                DownloadResultCode   = $DownloadResultCode
                InstallResultCode    = $InstallResultCode
                RebootRequired       = $RebootRequired
                InstallThrowsHResult = $InstallThrowsHResult
                AcceptEulaCalls      = 0
            }
            $update | Add-Member -MemberType ScriptMethod -Name AcceptEula -Value {
                $this.AcceptEulaCalls++
                $this.EulaAccepted = $true
            }
            return $update
        }

        # Sessão falsa (IUpdateSession) com busca, download e instalação simulados.
        function New-FakeSession {
            param(
                [object[]] $SoftwareUpdates = @(),
                [object[]] $DriverUpdates   = @(),
                [int]      $SearchFailures  = 0
            )

            $searcher = [pscustomobject] @{
                Software = $SoftwareUpdates
                Drivers  = $DriverUpdates
                Failures = $SearchFailures
                Criteria = [System.Collections.Generic.List[string]]::new()
            }
            $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
                param($criteria)
                $this.Criteria.Add($criteria)
                if ($this.Failures -gt 0) {
                    $this.Failures--
                    throw 'Falha simulada na busca (0x8024402C)'
                }
                $found = if ($criteria -like "*Type='Driver'*") { $this.Drivers } else { $this.Software }
                return [pscustomobject] @{ Updates = @($found) }
            }

            $downloader = [pscustomobject] @{ Updates = $null; Calls = 0 }
            $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value {
                $this.Calls++
                $update = $this.Updates.Items[0]
                return [pscustomobject] @{ ResultCode = $update.DownloadResultCode; HResult = 0 }
            }

            $installer = [pscustomobject] @{ Updates = $null; ForceQuiet = $false; Calls = 0 }
            $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
                $this.Calls++
                $update = $this.Updates.Items[0]
                if ($update.InstallThrowsHResult -ne 0) {
                    throw [System.Runtime.InteropServices.COMException]::new('Erro COM simulado', $update.InstallThrowsHResult)
                }
                $result = [pscustomobject] @{ Update = $update }
                $result | Add-Member -MemberType ScriptMethod -Name GetUpdateResult -Value {
                    param($index)
                    return [pscustomobject] @{
                        ResultCode     = $this.Update.InstallResultCode
                        HResult        = if ($this.Update.InstallResultCode -in 2, 3) { 0 } else { -2145124318 }
                        RebootRequired = $this.Update.RebootRequired
                    }
                }
                return $result
            }

            $session = [pscustomobject] @{
                ClientApplicationID = $null
                Searcher            = $searcher
                Downloader          = $downloader
                Installer           = $installer
            }
            $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher   -Value { $this.Searcher }
            $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value { $this.Downloader }
            $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller  -Value { $this.Installer }
            return $session
        }

        # Coleção falsa (IUpdateCollection).
        function New-FakeUpdateCollection {
            $collection = [pscustomobject] @{ Items = [System.Collections.Generic.List[object]]::new() }
            $collection | Add-Member -MemberType ScriptMethod -Name Add -Value {
                param($update)
                $this.Items.Add($update)
                return $this.Items.Count - 1
            }
            return $collection
        }

        function Clear-FailureFile {
            if (Test-Path -LiteralPath $failuresFile) {
                Remove-Item -LiteralPath $failuresFile
            }
        }
    }

    BeforeEach {
        # Valores padrão dos parâmetros do script; cada teste altera só o que precisa.
        $SearchOnly      = $false
        $ExcludeDrivers  = $false
        $ExcludeOptional = $false

        # Mensagens para o técnico: simuladas para não poluir a saída e para poder conferir o texto.
        Mock Write-Status { }
    }

    Context 'Carregamento do script' {

        It 'carregado por dot-source, define as funções e não executa o ciclo' {
            $guardRoot = Join-Path $TestDrive 'guarda'

            . $scriptPath -RootDir $guardRoot

            Get-Command Install-WindowsUpdates -CommandType Function | Should -Not -BeNullOrEmpty
            $guardRoot | Should -Not -Exist

            # Restaura os caminhos usados pelos demais testes.
            . $scriptPath -RootDir $testRoot
        }

        It 'usa os caminhos dentro de -RootDir' {
            $logFile      | Should -Be (Join-Path $testRoot 'Logs\windows-update.log')
            $failuresFile | Should -Be (Join-Path $testRoot 'windows-update-failures.json')
        }
    }

    Context 'Get-UpdateLabel' {

        It 'mostra o KB e o título' {
            Get-UpdateLabel -Update (New-FakeUpdate -Kb '5043080' -Title 'Atualização X') |
                Should -Be 'KB5043080 - Atualização X'
        }

        It 'mostra "sem KB" quando a atualização não tem KB (ex.: drivers)' {
            Get-UpdateLabel -Update (New-FakeUpdate -Kb '' -Title 'Intel - System - 1.0') |
                Should -Be 'sem KB - Intel - System - 1.0'
        }
    }

    Context 'Select-InstallableUpdate: regras de seleção' {

        It 'seleciona uma atualização comum' {
            $update = New-FakeUpdate

            $selected = Select-InstallableUpdate -Updates @($update) -FailureCounts @{}

            $selected.Count | Should -Be 1
        }

        It 'retorna uma lista mesmo com uma só atualização, e lista vazia sem nenhuma' {
            (Select-InstallableUpdate -Updates @(New-FakeUpdate) -FailureCounts @{}).Count | Should -Be 1
            (Select-InstallableUpdate -Updates @() -FailureCounts @{}).Count | Should -Be 0
        }

        It 'regra 1: ignora atualização de versão do Windows (categoria Upgrades)' {
            $upgrade = New-FakeUpdate -Title 'Windows 11, version 25H2' -CategoryIds $previewUpgradeCategory

            (Select-InstallableUpdate -Updates @($upgrade) -FailureCounts @{}).Count | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*atualização de versão do Windows*: 1' }
        }

        It 'regra 2: ignora prévias pelo título (<_>)' -ForEach @(
            '2026-09 Cumulative Update Preview for Windows 11 Version 24H2',
            'Atualização cumulativa de visualização para Windows 11',
            'Atualizacao cumulativa de visualizacao para Windows 11',
            'Prévia da atualização cumulativa do .NET Framework'
        ) {
            $preview = New-FakeUpdate -Title $_

            (Select-InstallableUpdate -Updates @($preview) -FailureCounts @{}).Count | Should -Be 0
        }

        It 'regra 2: não confunde títulos parecidos com prévia (<_>)' -ForEach @(
            'Visualizador de Fotos - atualização',
            'Previous version compatibility update'
        ) {
            (Select-InstallableUpdate -Updates @(New-FakeUpdate -Title $_) -FailureCounts @{}).Count | Should -Be 1
        }

        It 'regra 3: inclui opcionais por padrão' {
            $optional = New-FakeUpdate -BrowseOnly $true

            (Select-InstallableUpdate -Updates @($optional) -FailureCounts @{}).Count | Should -Be 1
        }

        It 'regra 3: ignora opcionais com -ExcludeOptional' {
            $ExcludeOptional = $true
            $optional = New-FakeUpdate -BrowseOnly $true

            (Select-InstallableUpdate -Updates @($optional) -FailureCounts @{}).Count | Should -Be 0
        }

        It 'regra 4: ignora SOFTWARE marcado como "pode pedir interação"' {
            $software = New-FakeUpdate -Type 1 -CanRequestUserInput $true

            (Select-InstallableUpdate -Updates @($software) -FailureCounts @{}).Count | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*software que pode pedir interação*: 1' }
        }

        It 'regra 4: instala DRIVER marcado como "pode pedir interação" e registra no log' {
            $driver = New-FakeUpdate -Type 2 -Kb '' -Title 'INTEL - System - 2134.1' -CanRequestUserInput $true -BrowseOnly $true

            (Select-InstallableUpdate -Updates @($driver) -FailureCounts @{}).Count | Should -Be 1
            Get-Content -LiteralPath $logFile -Raw | Should -BeLike "*será instalado em modo silencioso: sem KB - INTEL - System - 2134.1*"
        }

        It 'regra 5: ignora atualização que falhou 2 vezes e avisa na tela' {
            $update = New-FakeUpdate -Id 'falha-2'

            (Select-InstallableUpdate -Updates @($update) -FailureCounts @{ 'falha-2' = 2 }).Count | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'AVISO: ignorando*falhou 2 vezes*' }
        }

        It 'regra 5: ainda tenta atualização que falhou só 1 vez' {
            $update = New-FakeUpdate -Id 'falha-1'

            (Select-InstallableUpdate -Updates @($update) -FailureCounts @{ 'falha-1' = 1 }).Count | Should -Be 1
        }

        It 'aplica as regras na ordem: versão do Windows vem antes de prévia' {
            $both = New-FakeUpdate -Title 'Windows 11 Insider Preview' -CategoryIds $previewUpgradeCategory

            [void] (Select-InstallableUpdate -Updates @($both) -FailureCounts @{})

            Should -Invoke Write-Status -ParameterFilter { $Message -like '*atualização de versão do Windows*' } -Times 1 -Exactly
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*atualização prévia*' } -Times 0 -Exactly
        }

        It 'mostra na tela o resumo das ignoradas por motivo' {
            $updates = @(
                (New-FakeUpdate -Title 'Cumulative Update Preview A'),
                (New-FakeUpdate -Title 'Cumulative Update Preview B'),
                (New-FakeUpdate -Type 1 -CanRequestUserInput $true),
                (New-FakeUpdate)
            )

            (Select-InstallableUpdate -Updates $updates -FailureCounts @{}).Count | Should -Be 1
            Should -Invoke Write-Status -ParameterFilter { $Message -eq 'Ignoradas por "atualização prévia": 2' } -Times 1 -Exactly
            Should -Invoke Write-Status -ParameterFilter { $Message -eq 'Ignoradas por "software que pode pedir interação do usuário": 1' } -Times 1 -Exactly
        }
    }

    Context 'Contagem de falhas por atualização' {

        BeforeEach {
            Clear-FailureFile
        }

        It 'sem arquivo, começa vazia' {
            $counts = Get-UpdateFailureCount

            $counts | Should -BeOfType [hashtable]
            $counts.Count | Should -Be 0
        }

        It 'grava e lê de volta as contagens como números' {
            Save-UpdateFailureCount -Counts @{ 'a' = 1; 'b' = 2 }

            $counts = Get-UpdateFailureCount

            $counts['a'] | Should -Be 1
            $counts['b'] | Should -Be 2
            $counts['b'] | Should -BeOfType [int]
        }
    }

    Context 'Find-PendingUpdate: busca' {

        BeforeEach {
            Mock Start-Sleep { }
        }

        It 'procura software e drivers por padrão' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -Id 's') -DriverUpdates @(New-FakeUpdate -Id 'd' -Type 2)

            $found = Find-PendingUpdate -Session $session

            $found.Count | Should -Be 2
            $session.Searcher.Criteria.Count | Should -Be 2
            $session.Searcher.Criteria | Should -Contain "IsInstalled=0 and IsHidden=0 and Type='Software'"
            $session.Searcher.Criteria | Should -Contain "IsInstalled=0 and IsHidden=0 and Type='Driver'"
        }

        It 'não procura drivers com -ExcludeDrivers' {
            $ExcludeDrivers = $true
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate) -DriverUpdates @(New-FakeUpdate -Type 2)

            (Find-PendingUpdate -Session $session).Count | Should -Be 1
            $session.Searcher.Criteria | Should -Not -Contain "IsInstalled=0 and IsHidden=0 and Type='Driver'"
        }

        It 'mantém a ordem devolvida pelo Windows Update (software primeiro, depois drivers)' {
            $software = 1..10 | ForEach-Object { New-FakeUpdate -Id "s$_" }
            $drivers  = 1..3  | ForEach-Object { New-FakeUpdate -Id "d$_" -Type 2 }
            $session  = New-FakeSession -SoftwareUpdates $software -DriverUpdates $drivers

            $ids = (Find-PendingUpdate -Session $session) | ForEach-Object { $_.Identity.UpdateID }

            ($ids -join ',') | Should -Be 's1,s2,s3,s4,s5,s6,s7,s8,s9,s10,d1,d2,d3'
        }

        It 'não duplica uma atualização que aparece nas duas buscas' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -Id 'igual') -DriverUpdates @(New-FakeUpdate -Id 'igual')

            (Find-PendingUpdate -Session $session).Count | Should -Be 1
        }

        It 'retorna lista vazia quando não há atualizações' {
            $found = Find-PendingUpdate -Session (New-FakeSession)

            , $found | Should -BeOfType [object[]]
            $found.Count | Should -Be 0
        }

        It 'tenta de novo após falhas na busca, aguardando 60 s entre as tentativas' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate) -SearchFailures 2

            (Find-PendingUpdate -Session $session).Count | Should -Be 1
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 60 }
            Should -Invoke Write-Status -Times 2 -Exactly -ParameterFilter { $Message -like 'Falha na busca (tentativa *' }
        }

        It 'desiste após 3 falhas seguidas com erro claro' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate) -SearchFailures 3

            { Find-PendingUpdate -Session $session } | Should -Throw 'Não foi possível procurar atualizações após 3 tentativas.'
        }
    }

    Context 'Assert-Prerequisite: pré-requisitos' {

        BeforeEach {
            Mock Test-IsAdministrator { $true }
            Mock Get-Service { [pscustomobject] @{ StartType = 'Manual'; Status = 'Running' } }
            Mock Start-Service { }
            Mock Get-PSDrive { [pscustomobject] @{ Free = 50GB } }
        }

        It 'passa quando tudo está OK' {
            { Assert-Prerequisite } | Should -Not -Throw
        }

        It 'exige administrador para instalar' {
            Mock Test-IsAdministrator { $false }

            { Assert-Prerequisite } | Should -Throw '*exige execução como administrador*'
        }

        It 'não exige administrador no modo -SearchOnly' {
            $SearchOnly = $true
            Mock Test-IsAdministrator { $false }

            { Assert-Prerequisite } | Should -Not -Throw
        }

        It 'falha se o serviço Windows Update estiver desativado' {
            Mock Get-Service { [pscustomobject] @{ StartType = 'Disabled'; Status = 'Stopped' } }

            { Assert-Prerequisite } | Should -Throw '*wuauserv*desativado*'
        }

        It 'inicia o serviço Windows Update se estiver parado' {
            Mock Get-Service { [pscustomobject] @{ StartType = 'Manual'; Status = 'Stopped' } }

            Assert-Prerequisite

            Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'wuauserv' }
        }

        It 'não inicia o serviço no modo -SearchOnly' {
            $SearchOnly = $true
            Mock Get-Service { [pscustomobject] @{ StartType = 'Manual'; Status = 'Stopped' } }

            Assert-Prerequisite

            Should -Invoke Start-Service -Times 0 -Exactly
        }

        It 'avisa (sem falhar) quando há menos de 10 GB livres em C:' {
            Mock Get-PSDrive { [pscustomobject] @{ Free = 4GB } }

            { Assert-Prerequisite } | Should -Not -Throw
            Should -Invoke Write-Status -Times 1 -Exactly -ParameterFilter { $Message -like 'AVISO: apenas 4 GB livres em C:*' }
        }
    }

    Context 'Install-WindowsUpdates: um ciclo completo' {

        BeforeEach {
            Clear-FailureFile
            Mock Assert-Prerequisite { }
            # No Pester 6, uma chamada que não bate com nenhum filtro dá erro. Esta simulação padrão repassa ao
            # New-Object real tudo o que não for objeto do Windows Update (ex.: as listas criadas pelo script).
            # O cmdlet é chamado pelo objeto CmdletInfo: pelo nome, mesmo qualificado, o Pester 6 interceptaria de novo.
            Mock New-Object {
                $realNewObject = $ExecutionContext.InvokeCommand.GetCmdlet('Microsoft.PowerShell.Utility\New-Object')
                & $realNewObject @PesterBoundParameters
            }
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.UpdateColl' } -MockWith { New-FakeUpdateCollection }
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.SystemInfo' } -MockWith { [pscustomobject] @{ RebootRequired = $false } }
        }

        It 'retorna 3010 sem procurar quando já há reinicialização pendente' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.SystemInfo' } -MockWith { [pscustomobject] @{ RebootRequired = $true } }

            Install-WindowsUpdates | Should -Be 3010
            $session.Searcher.Criteria.Count | Should -Be 0
        }

        It 'retorna 0 quando não há atualizações' {
            $session = New-FakeSession
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 0
        }

        It 'retorna 0 quando todas as atualizações encontradas são ignoradas' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -Title 'Cumulative Update Preview')
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 0
            $session.Installer.Calls | Should -Be 0
        }

        It 'no modo -SearchOnly lista, mas não baixa nem instala' {
            $SearchOnly = $true
            $session = New-FakeSession -SoftwareUpdates @((New-FakeUpdate), (New-FakeUpdate))
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 0
            $session.Downloader.Calls | Should -Be 0
            $session.Installer.Calls | Should -Be 0
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'Modo -SearchOnly*' }
        }

        It 'retorna 2 ao instalar tudo sem reboot, uma atualização por vez, em modo silencioso' {
            $session = New-FakeSession -SoftwareUpdates @((New-FakeUpdate), (New-FakeUpdate), (New-FakeUpdate))
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            $output = @(Install-WindowsUpdates)

            $output.Count | Should -Be 1
            $output[0] | Should -Be 2
            $session.Installer.Calls | Should -Be 3
            $session.Installer.ForceQuiet | Should -BeTrue
            $session.ClientApplicationID | Should -Be 'WorkstationProvisioning'
            Should -Invoke Write-Status -ParameterFilter { $Message -like '`[3/3`] Instalada.' }
        }

        It 'retorna 3010 quando uma atualização pede reinicialização' {
            $session = New-FakeSession -SoftwareUpdates @((New-FakeUpdate), (New-FakeUpdate -RebootRequired $true))
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 3010
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*Instalada (requer reinicialização).' }
        }

        It 'retorna 3010 quando o Windows indica reinicialização pendente após instalar' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate)
            $systemInfoCalls = [ref] 0
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.SystemInfo' } -MockWith {
                $systemInfoCalls.Value++
                [pscustomobject] @{ RebootRequired = ($systemInfoCalls.Value -gt 1) }
            }

            Install-WindowsUpdates | Should -Be 3010
        }

        It 'não baixa de novo uma atualização já baixada' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -IsDownloaded $true)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2
            $session.Downloader.Calls | Should -Be 0
            $session.Installer.Calls | Should -Be 1
        }

        It 'aceita a licença (EULA) quando necessário' {
            $update = New-FakeUpdate -EulaAccepted $false
            $session = New-FakeSession -SoftwareUpdates @($update)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            [void] (Install-WindowsUpdates)

            $update.AcceptEulaCalls | Should -Be 1
        }

        It 'considera instalada uma atualização com "sucesso com erros" (ResultCode 3)' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -Id 'parcial' -InstallResultCode 3)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2
            (Get-UpdateFailureCount).ContainsKey('parcial') | Should -BeFalse
        }

        It 'continua com as demais quando uma instalação falha, e conta a falha' {
            $session = New-FakeSession -SoftwareUpdates @(
                (New-FakeUpdate -Id 'ok-1'),
                (New-FakeUpdate -Id 'falha' -InstallResultCode 4),
                (New-FakeUpdate -Id 'ok-2')
            )
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2
            $session.Installer.Calls | Should -Be 3
            (Get-UpdateFailureCount)['falha'] | Should -Be 1
            Should -Invoke Write-Status -ParameterFilter { $Message -like '`[2/3`] FALHA:*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like 'Resumo do ciclo: 2 instaladas, 1 com falha*' }
        }

        It 'mostra um único HResult, o do Windows Update, quando a instalação termina com erro' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -InstallResultCode 4)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            [void] (Install-WindowsUpdates)

            Should -Invoke Write-Status -Times 1 -Exactly -ParameterFilter {
                $Message -like '*FALHA:*HResult 0x80240022*' -and ([regex]::Matches($Message, 'HResult').Count -eq 1)
            }
        }

        It 'mostra o HResult do erro COM quando a própria API falha' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -InstallThrowsHResult -2145124329)   # 0x80240017
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2

            Should -Invoke Write-Status -Times 1 -Exactly -ParameterFilter {
                $Message -like '*FALHA:*Erro COM simulado*HResult 0x80240017*' -and ([regex]::Matches($Message, 'HResult').Count -eq 1)
            }
        }

        It 'não instala uma atualização cujo download falhou, e conta a falha' {
            $session = New-FakeSession -SoftwareUpdates @(
                (New-FakeUpdate -Id 'sem-download' -DownloadResultCode 4),
                (New-FakeUpdate -Id 'ok')
            )
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2
            $session.Installer.Calls | Should -Be 1
            (Get-UpdateFailureCount)['sem-download'] | Should -Be 1
        }

        It 'soma uma nova falha à contagem de ciclos anteriores' {
            Save-UpdateFailureCount -Counts @{ 'repetida' = 1 }
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -Id 'repetida' -InstallResultCode 4)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            [void] (Install-WindowsUpdates)

            (Get-UpdateFailureCount)['repetida'] | Should -Be 2
        }

        It 'apaga a contagem de falhas de uma atualização que passou a instalar' {
            Save-UpdateFailureCount -Counts @{ 'recuperada' = 1 }
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -Id 'recuperada')
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2
            (Get-UpdateFailureCount).ContainsKey('recuperada') | Should -BeFalse
        }

        It 'retorna 2 (procurar de novo) quando todas as instalações do ciclo falham' {
            $session = New-FakeSession -SoftwareUpdates @(New-FakeUpdate -InstallResultCode 4)
            Mock New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } -MockWith { $session }

            Install-WindowsUpdates | Should -Be 2
        }
    }
}
