# Testes de unidade de scripts\Install-CorporateSoftware.ps1.
#
# SIMULADOS: caixa de credencial (Get-Credential), conexão aos compartilhamentos (New/Remove-SmbMapping),
# execução dos instaladores (Start-Process/Start-CorporateProcess), programas instalados e a pergunta da licença (Read-Host).
# Cópias de pasta/arquivo e atalhos rodam de verdade, na pasta temporária do Pester ($TestDrive).
# Nenhum servidor é acessado e nada é instalado.
# Requer Pester 5 ou superior (testado com Pester 6.2 no Windows PowerShell 5.1).
#
# Como rodar, a partir da raiz do projeto:
#   Import-Module Pester -MinimumVersion 5.0
#   Invoke-Pester -Path .\tests\Unit\Install-CorporateSoftware.Tests.ps1 -Output Detailed

Describe 'Install-CorporateSoftware.ps1' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\scripts\Install-CorporateSoftware.ps1')
        $projectConfig = Join-Path $PSScriptRoot '..\..\config\corporate-apps.json'

        # Substitui o Write-Log do orquestrador: guarda as mensagens para conferência.
        $logged = [System.Collections.Generic.List[string]]::new()
        function Write-Log { param($Message, $Level = 'INFO') $logged.Add("[$Level] $Message") }

        $testPassword = 'SenhaDeTeste@123'
        function New-TestCredential {
            return [pscredential]::new('LAQUILA\tecnico', (ConvertTo-SecureString $testPassword -AsPlainText -Force))
        }

        function New-TestItem {
            param([hashtable] $Fields)
            $base = @{ id = 'item'; name = 'Item de teste'; type = 'exe'; path = 'C:\nao\usado.exe'; required = $true }
            foreach ($key in $Fields.Keys) { $base[$key] = $Fields[$key] }
            return [pscustomobject] $base
        }

        function Set-TestConfig {
            param([string] $Path, [string[]] $Shares, [object[]] $Items)
            @{ shares = $Shares; items = $Items } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    BeforeEach {
        $logged.Clear()
        $testLogFile = Join-Path $TestDrive 'corporate-software.log'
        $script:corporateLogFile = $testLogFile
        $workDir = Join-Path $TestDrive 'work'
        Mock Write-Host { }
    }

    Context 'Read-CorporateConfig' {

        It 'aceita o config\corporate-apps.json real, na ordem do procedimento' {
            $config = Read-CorporateConfig -Path $projectConfig

            ($config.Items | ForEach-Object { $_.id }) -join ',' |
                Should -Be 'office,withsecure,odbc11,everest30,everest211-files,ntwdblib,bde-info-52,bde-511,bde-config,everest211-shortcuts,forticlient-vpn,forticlient-vpn-config'
            $config.Shares | Should -Contain '\\marketing\softwares'
            $config.Shares | Should -Contain '\\fs01\Everest30'
        }

        It 'BDE: Update 5.2 antes do 5.1.1 Full, e a configuração e os atalhos depois' {
            $ids = @((Read-CorporateConfig -Path $projectConfig).Items | ForEach-Object { $_.id })

            [array]::IndexOf($ids, 'bde-info-52') | Should -BeLessThan ([array]::IndexOf($ids, 'bde-511'))
            [array]::IndexOf($ids, 'bde-511')     | Should -BeLessThan ([array]::IndexOf($ids, 'bde-config'))
            [array]::IndexOf($ids, 'bde-config')  | Should -BeLessThan ([array]::IndexOf($ids, 'everest211-shortcuts'))
        }

        It 'não guarda a chave completa do antivírus, só um padrão' {
            $withSecure = (Read-CorporateConfig -Path $projectConfig).Items | Where-Object id -eq 'withsecure'

            $withSecure.pathPattern | Should -BeLike '*ElementsAgentInstaller*E03G*.exe'
            # Nenhuma sequência no formato de chave (XXXX-XXXX-XXXX-XXXX) no arquivo versionado.
            Get-Content -LiteralPath $projectConfig -Raw | Should -Not -Match '[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}'
        }

        It 'falha se o arquivo não existir' {
            { Read-CorporateConfig -Path (Join-Path $TestDrive 'nao-existe.json') } | Should -Throw '*não encontrada*'
        }

        It 'recusa tipo inválido' {
            $file = Join-Path $TestDrive 'tipo.json'
            Set-TestConfig -Path $file -Shares @() -Items @(New-TestItem @{ type = 'zip' })

            { Read-CorporateConfig -Path $file } | Should -Throw "*tipo 'zip' inválido*"
        }

        It 'exige os campos de cada tipo (ex.: odt sem odtConfig)' {
            $file = Join-Path $TestDrive 'odt.json'
            Set-TestConfig -Path $file -Shares @() -Items @(New-TestItem @{ type = 'odt' })

            { Read-CorporateConfig -Path $file } | Should -Throw "*sem o campo 'odtConfig'*"
        }

        It "exige 'required' verdadeiro ou falso" {
            $file = Join-Path $TestDrive 'required.json'
            Set-TestConfig -Path $file -Shares @() -Items @(New-TestItem @{ required = 'sim' })

            { Read-CorporateConfig -Path $file } | Should -Throw "*'required' precisa ser true ou false*"
        }
    }

    Context 'Resolve-CorporateItemPath' {

        BeforeAll {
            $folder = Join-Path $TestDrive 'instaladores'
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'ElementsAgentInstaller[AAAA-E03G-BBBB].exe') -Value 'x'
            Set-Content -LiteralPath (Join-Path $folder 'ElementsAgentInstaller[CCCC-XXXX-DDDD].exe') -Value 'x'
        }

        It 'aceita um caminho que existe' {
            $file = Join-Path $folder 'ElementsAgentInstaller[AAAA-E03G-BBBB].exe'

            Resolve-CorporateItemPath -Item (New-TestItem @{ path = $file }) | Should -Be $file
        }

        It 'falha se o caminho não existir' {
            { Resolve-CorporateItemPath -Item (New-TestItem @{ path = (Join-Path $folder 'nao.exe') }) } | Should -Throw '*não encontrado*'
        }

        It 'encontra exatamente um arquivo pelo padrão (o de E03G)' {
            $item = New-TestItem @{ path = ''; pathPattern = (Join-Path $folder 'ElementsAgentInstaller*E03G*.exe') }

            Resolve-CorporateItemPath -Item $item | Should -BeLike '*E03G*'
        }

        It 'falha se o padrão encontrar mais de um arquivo' {
            $item = New-TestItem @{ path = ''; pathPattern = (Join-Path $folder 'ElementsAgentInstaller*.exe') }

            { Resolve-CorporateItemPath -Item $item } | Should -Throw '*encontrou 2 arquivo(s)*'
        }
    }

    Context 'Test-CorporateItemInstalled' {

        It 'item sem detect é sempre executado' {
            Test-CorporateItemInstalled -Item (New-TestItem @{}) | Should -BeFalse
        }

        It 'detecta por caminho' {
            $existing = Join-Path $TestDrive 'existe.txt'
            Set-Content -LiteralPath $existing -Value 'x'

            Test-CorporateItemInstalled -Item (New-TestItem @{ detect = [pscustomobject] @{ path = $existing } }) | Should -BeTrue
            Test-CorporateItemInstalled -Item (New-TestItem @{ detect = [pscustomobject] @{ path = (Join-Path $TestDrive 'nao.txt') } }) | Should -BeFalse
        }

        It 'detecta pelo nome em Programas e Recursos (com curinga)' {
            Mock Get-CorporateInstalledProgramName { , @('Microsoft 365 Apps para negócios - pt-br') }

            Test-CorporateItemInstalled -Item (New-TestItem @{ detect = [pscustomobject] @{ displayName = 'Microsoft 365*' } }) | Should -BeTrue
            Test-CorporateItemInstalled -Item (New-TestItem @{ detect = [pscustomobject] @{ displayName = 'WithSecure*' } }) | Should -BeFalse
        }
    }

    Context 'Detecção por versão mínima (Office)' {

        BeforeAll {
            # Um executável real do Windows, só para ler a versão.
            $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
        }

        It 'versão igual ou maior que a mínima: instalado' {
            $item = New-TestItem @{ detect = [pscustomobject] @{ path = $notepad; minimumVersion = '1.0' } }
            Test-CorporateItemInstalled -Item $item | Should -BeTrue
        }

        It 'versão antiga (ex.: Office de 2019): conta como não instalado, para o ODT atualizar' {
            $item = New-TestItem @{ detect = [pscustomobject] @{ path = $notepad; minimumVersion = '99.0' } }
            Test-CorporateItemInstalled -Item $item | Should -BeFalse
        }

        It 'arquivo sem versão: não instalado' {
            $file = Join-Path $TestDrive 'semversao.exe'; Set-Content -LiteralPath $file -Value 'x'
            Test-CorporateItemInstalled -Item (New-TestItem @{ detect = [pscustomobject] @{ path = $file; minimumVersion = '1.0' } }) | Should -BeFalse
        }

        It 'Office no JSON real: WINWORD.EXE com versão mínima posterior à cópia antiga do servidor (16.0.11425)' {
            $office = (Read-CorporateConfig -Path $projectConfig).Items | Where-Object id -eq 'office'
            $office.detect.path | Should -BeLike '*\WINWORD.EXE'
            [version] $office.detect.minimumVersion | Should -BeGreaterThan ([version] '16.0.11425.20204')
        }

        It 'recusa minimumVersion inválida' {
            $file = Join-Path $TestDrive 'versao.json'
            Set-TestConfig -Path $file -Shares @() -Items @(New-TestItem @{ detect = @{ path = 'C:\x.exe'; minimumVersion = 'abc' } })
            { Read-CorporateConfig -Path $file } | Should -Throw "*minimumVersion*"
        }

        It 'BDE 5.2 no JSON real: responde Cancel ao pedido de reinício (reinício pendente)' {
            $rule = @(((Read-CorporateConfig -Path $projectConfig).Items | Where-Object id -eq 'bde-info-52').prompts)[0]
            'This system must be restarted to complete the installation.' | Should -Match $rule.text
            $rule.button         | Should -Be 'Cancel'
            $rule.restartPending | Should -BeTrue
        }

        It 'BDE 5.1.1 no JSON real: aceita as janelas do instalador (pasta, espaço em disco, criar pasta)' {
            $rules = @(((Read-CorporateConfig -Path $projectConfig).Items | Where-Object id -eq 'bde-511').prompts)
            $answers = @{
                'The Borland Database Engine will be installed/upgraded in the following directory:' = 'OK'
                'There is not enough space on drive C:.  Install to this location anyway?'           = 'Yes'
                'The specified directory does not exist.  Create it?'                                 = 'Yes'
            }
            foreach ($text in $answers.Keys) {
                $rule = $rules | Where-Object { $text -match $_.text } | Select-Object -First 1
                $rule.button | Should -Be $answers[$text]
            }
        }

        It 'BDE 5.1.1 no JSON real: digita a pasta das máquinas manuais (Borland\Common Files\BDE)' {
            $rules = @(((Read-CorporateConfig -Path $projectConfig).Items | Where-Object id -eq 'bde-511').prompts)
            $folderRule = $rules | Where-Object { 'will be installed/upgraded in the following directory' -match $_.text }
            $folderRule.setText | Should -Be 'C:\Program Files (x86)\Borland\Common Files\BDE'
        }

        It 'BDE 5.1.1 no JSON real: detecta nas duas pastas possíveis, e o IDAPI32.CFG vai para a pasta registrada pelo BDE' {
            $items = (Read-CorporateConfig -Path $projectConfig).Items
            @(($items | Where-Object id -eq 'bde-511').detect.path) | Should -Contain 'C:\Program Files (x86)\Common Files\Borland Shared\BDE\idapi32.dll'
            ($items | Where-Object id -eq 'bde-config').destinationRegistry.value | Should -Be 'CONFIGFILE01'
        }

        It 'recusa regra de prompts sem botão' {
            $file = Join-Path $TestDrive 'prompts.json'
            Set-TestConfig -Path $file -Shares @() -Items @(New-TestItem @{ prompts = @(@{ text = 'restart' }) })
            { Read-CorporateConfig -Path $file } | Should -Throw "*precisa de 'text' e 'button'*"
        }

        It 'detecta por uma lista de caminhos (basta um existir)' {
            $existing = Join-Path $TestDrive 'idapi32.dll'; Set-Content -LiteralPath $existing -Value 'x'
            $item = New-TestItem @{ detect = [pscustomobject] @{ path = @((Join-Path $TestDrive 'nao\idapi32.dll'), $existing) } }
            Test-CorporateItemInstalled -Item $item | Should -BeTrue
        }
    }

    Context 'Janelas do instalador respondidas sozinhas (janela real)' {

        BeforeAll {
            # Abre, em outro processo, uma caixa de mensagem igual às dos instaladores. O exit code é o botão
            # clicado (1 = OK, 2 = Cancel, 6 = Yes, 7 = No). Nada é instalado ou reiniciado.
            function Start-TestPrompt {
                param([string] $Text, [string] $Buttons = 'OKCancel')
                $command = "Add-Type -AssemblyName System.Windows.Forms; exit [int][System.Windows.Forms.MessageBox]::Show('$Text', 'Teste do provisionamento', '$Buttons')"
                $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', $command -PassThru
                $null = $process.Handle
                $deadline = (Get-Date).AddSeconds(20)
                while ((Get-Date) -lt $deadline) {
                    $process.Refresh()
                    if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
                    Start-Sleep -Milliseconds 250
                }
                Start-Sleep -Milliseconds 500
                return $process
            }
        }

        It 'clica em Cancel no pedido de reinício e o instalador continua' {
            $process = Start-TestPrompt -Text 'This system must be restarted to complete the installation. Click the OK button to restart this computer. Press Cancel to return to Windows without restarting.'
            $rules = @([pscustomobject] @{ text = 'must be restarted'; button = 'Cancel'; restartPending = $true })
            try {
                Wait-CorporateProcess -Process $process -Prompts $rules -IntervalMilliseconds 500 | Should -BeTrue
                $process.ExitCode | Should -Be 2
            }
            finally {
                if (-not $process.HasExited) { $process.Kill() }
            }
        }

        It 'clica em Yes no aviso de espaço em disco do BDE (sem reinício pendente)' {
            $process = Start-TestPrompt -Text 'There is not enough space on drive C:.  Install to this location anyway?' -Buttons 'YesNo'
            $rules = @([pscustomobject] @{ text = 'not enough space on drive'; button = 'Yes' })
            try {
                Wait-CorporateProcess -Process $process -Prompts $rules -IntervalMilliseconds 500 | Should -BeFalse
                $process.ExitCode | Should -Be 6
            }
            finally {
                if (-not $process.HasExited) { $process.Kill() }
            }
        }

        It 'não mexe em janelas que não estão nas regras' {
            $process = Start-TestPrompt -Text 'Instalação concluída.'
            $rules = @([pscustomobject] @{ text = 'must be restarted'; button = 'Cancel' })
            try {
                Invoke-CorporatePromptAnswer -ProcessId $process.Id -Prompts $rules | Should -BeNullOrEmpty
                $process.HasExited | Should -BeFalse
            }
            finally {
                if (-not $process.HasExited) { $process.Kill() }
            }
        }

        It 'digita a pasta no campo de texto e clica em OK (janela como a do instalador do BDE)' {
            # Janela com rótulo, campo de texto com a pasta sugerida e botão OK. Ao fechar, grava o que estava
            # no campo, para conferir o que foi digitado.
            $resultFile = Join-Path $TestDrive 'pasta-escolhida.txt'
            $formScript = Join-Path $TestDrive 'janela-bde.ps1'
            Set-Content -LiteralPath $formScript -Encoding UTF8 -Value @"
Add-Type -AssemblyName System.Windows.Forms
`$form = New-Object System.Windows.Forms.Form
`$form.Text = 'Borland Database Engine Installation/Upgrade'
`$label = New-Object System.Windows.Forms.Label
`$label.Text = 'The Borland Database Engine will be installed/upgraded in the following directory:'
`$label.SetBounds(10, 10, 460, 20)
`$box = New-Object System.Windows.Forms.TextBox
`$box.Text = 'C:\Program Files (x86)\Common Files\Borland Shared\BDE'
`$box.SetBounds(10, 40, 460, 20)
`$ok = New-Object System.Windows.Forms.Button
`$ok.Text = 'OK'
`$ok.DialogResult = 'OK'
`$ok.SetBounds(10, 70, 80, 25)
`$form.Controls.AddRange(@(`$label, `$box, `$ok))
`$form.AcceptButton = `$ok
`$form.ClientSize = New-Object System.Drawing.Size(480, 110)
[void] `$form.ShowDialog()
Set-Content -LiteralPath '$resultFile' -Value `$box.Text -Encoding UTF8
exit 0
"@
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $formScript -PassThru
            $null = $process.Handle
            $rules = @([pscustomobject] @{ text = 'will be installed/upgraded in the following directory'; button = 'OK'; setText = 'C:\Program Files (x86)\Borland\Common Files\BDE' })
            try {
                $deadline = (Get-Date).AddSeconds(30)
                $answered = $null
                while ($null -eq $answered -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 500
                    $answered = Invoke-CorporatePromptAnswer -ProcessId $process.Id -Prompts $rules
                }
                $answered | Should -Not -BeNullOrEmpty
                $process.WaitForExit(15000) | Should -BeTrue
                Get-Content -LiteralPath $resultFile | Should -Be 'C:\Program Files (x86)\Borland\Common Files\BDE'
            }
            finally {
                if (-not $process.HasExited) { $process.Kill() }
            }
        }

        It 'não mexe em janelas que não estão nas regras (segunda verificação, com outra regra)' {
            $process = Start-TestPrompt -Text 'Instalação concluída.'
            $rules = @([pscustomobject] @{ text = 'installed/upgraded'; button = 'OK'; setText = 'C:\x' })
            try {
                Invoke-CorporatePromptAnswer -ProcessId $process.Id -Prompts $rules | Should -BeNullOrEmpty
                $process.HasExited | Should -BeFalse
            }
            finally {
                if (-not $process.HasExited) { $process.Kill() }
            }
        }
    }

    Context 'Connect-CorporateShare: credencial e compartilhamentos' {

        BeforeEach {
            $share1 = Join-Path $TestDrive 'share1'; $share2 = Join-Path $TestDrive 'share2'
            New-Item -ItemType Directory -Force -Path $share1, $share2 | Out-Null
            Mock Remove-SmbMapping { }
        }

        It 'abre a caixa de credencial do Windows já com o domínio e conecta aos compartilhamentos' {
            Mock Get-Credential { New-TestCredential }
            Mock New-SmbMapping { }

            $connected = Connect-CorporateShare -Shares @($share1, $share2) -DomainPrefix 'LAQUILA'

            $connected.Count | Should -Be 2
            Should -Invoke Get-Credential -Times 1 -Exactly -ParameterFilter { $UserName -eq 'LAQUILA\' }
            Should -Invoke New-SmbMapping -Times 2 -Exactly -ParameterFilter { $UserName -eq 'LAQUILA\tecnico' -and -not $Persistent }
        }

        It 'pede de novo quando a credencial é recusada e desfaz as conexões parciais' {
            Mock Get-Credential { New-TestCredential }
            $calls = [ref] 0
            Mock New-SmbMapping { $calls.Value++; if ($calls.Value -eq 2) { throw 'Falha de logon: usuário ou senha incorretos (simulado)' } }

            $connected = Connect-CorporateShare -Shares @($share1, $share2) -DomainPrefix 'LAQUILA'

            $connected.Count | Should -Be 2
            Should -Invoke Get-Credential -Times 2 -Exactly
            Should -Invoke Remove-SmbMapping -Times 1 -Exactly -ParameterFilter { $RemotePath -eq $share1 }
        }

        It 'desiste depois de 3 tentativas canceladas' {
            Mock Get-Credential { $null }
            Mock New-SmbMapping { }

            { Connect-CorporateShare -Shares @($share1) -DomainPrefix 'LAQUILA' } | Should -Throw '*após 3 tentativas*'
            Should -Invoke New-SmbMapping -Times 0 -Exactly
        }

        It 'nunca grava a senha no log' {
            Mock Get-Credential { New-TestCredential }
            $calls = [ref] 0
            Mock New-SmbMapping { $calls.Value++; if ($calls.Value -eq 1) { throw 'recusada (simulado)' } }

            [void] (Connect-CorporateShare -Shares @($share1) -DomainPrefix 'LAQUILA')

            ($logged -join "`n") | Should -Not -Match ([regex]::Escape($testPassword))
            Get-Content -LiteralPath $testLogFile -Raw | Should -Not -Match ([regex]::Escape($testPassword))
        }
    }

    Context 'Invoke-CorporateItem: tipos de item' {

        It 'copy-folder copia a pasta inteira (robocopy)' {
            $source = Join-Path $TestDrive 'origem'; $destination = Join-Path $TestDrive 'destino\everest1'
            New-Item -ItemType Directory -Force -Path (Join-Path $source 'sub') | Out-Null
            Set-Content -LiteralPath (Join-Path $source 'MEU.exe') -Value 'x'
            Set-Content -LiteralPath (Join-Path $source 'sub\a.txt') -Value 'x'

            Invoke-CorporateItem -Item (New-TestItem @{ type = 'copy-folder'; source = $source; destination = $destination }) -ConfigDir $TestDrive -WorkDir $workDir

            Join-Path $destination 'MEU.exe'   | Should -Exist
            Join-Path $destination 'sub\a.txt' | Should -Exist
        }

        It 'copy-file copia e substitui o arquivo (ex.: IDAPI32.CFG)' {
            $source = Join-Path $TestDrive 'IDAPI32.CFG'; $destination = Join-Path $TestDrive 'Borland\BDE\IDAPI32.CFG'
            Set-Content -LiteralPath $source -Value 'configuração nova'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Set-Content -LiteralPath $destination -Value 'configuração antiga'

            Invoke-CorporateItem -Item (New-TestItem @{ type = 'copy-file'; source = $source; destination = $destination }) -ConfigDir $TestDrive -WorkDir $workDir

            Get-Content -LiteralPath $destination | Should -Be 'configuração nova'
        }

        It 'copy-file com destinationRegistry: copia para onde o registro indica (CONFIGFILE01 do BDE)' {
            # Chave de teste no HKCU, removida no final.
            $key = 'HKCU:\Software\WorkstationProvisioningTests\Database Engine'
            $destination = Join-Path $TestDrive 'Borland Shared\BDE\IDAPI32.CFG'
            New-Item -Path $key -Force | Out-Null
            try {
                New-ItemProperty -Path $key -Name 'CONFIGFILE01' -Value $destination -PropertyType String -Force | Out-Null
                $source = Join-Path $TestDrive 'IDAPI32-reg.CFG'; Set-Content -LiteralPath $source -Value 'aliases'
                $item = New-TestItem @{ type = 'copy-file'; source = $source; destinationRegistry = [pscustomobject] @{ key = $key; value = 'CONFIGFILE01' } }

                Invoke-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir

                Get-Content -LiteralPath $destination | Should -Be 'aliases'
            }
            finally {
                Remove-Item -Path 'HKCU:\Software\WorkstationProvisioningTests' -Recurse -Force
            }
        }

        It 'copy-file com destinationRegistry falha se o programa não registrou o caminho' {
            $source = Join-Path $TestDrive 'IDAPI32-x.CFG'; Set-Content -LiteralPath $source -Value 'x'
            $item = New-TestItem @{ type = 'copy-file'; source = $source; destinationRegistry = [pscustomobject] @{ key = 'HKCU:\Software\WorkstationProvisioningTests\NaoExiste'; value = 'CONFIGFILE01' } }

            { Invoke-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir } | Should -Throw '*O programa foi instalado?*'
        }

        It 'shortcuts cria os atalhos Everest e EverestLite com o destino e a pasta de trabalho corretos' {
            $folder = Join-Path $TestDrive 'everest1'; $desktop = Join-Path $TestDrive 'Public\Desktop'
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'MEU.exe') -Value 'x'
            Set-Content -LiteralPath (Join-Path $folder 'MeuLite.exe') -Value 'x'
            $item = New-TestItem @{ type = 'shortcuts'; destination = $desktop; shortcuts = @(
                [pscustomobject] @{ name = 'Everest';     target = (Join-Path $folder 'MEU.exe') },
                [pscustomobject] @{ name = 'EverestLite'; target = (Join-Path $folder 'MeuLite.exe') }
            ) }

            Invoke-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir

            $shell = New-Object -ComObject 'WScript.Shell'
            $everest = $shell.CreateShortcut((Join-Path $desktop 'Everest.lnk'))
            $everest.TargetPath       | Should -Be (Join-Path $folder 'MEU.exe')
            $everest.WorkingDirectory | Should -Be $folder
            $shell.CreateShortcut((Join-Path $desktop 'EverestLite.lnk')).TargetPath | Should -Be (Join-Path $folder 'MeuLite.exe')
        }

        It 'shortcuts falha se o programa não existir' {
            $item = New-TestItem @{ type = 'shortcuts'; destination = (Join-Path $TestDrive 'desk'); shortcuts = @(
                [pscustomobject] @{ name = 'Everest'; target = (Join-Path $TestDrive 'nao\MEU.exe') }) }

            { Invoke-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir } | Should -Throw '*destino do atalho não encontrado*'
        }

        It 'exe roda o instalador sem o Shell, com os argumentos silenciosos, e aceita 0/3010/1641' {
            $installer = Join-Path $TestDrive 'setup.exe'; Set-Content -LiteralPath $installer -Value 'x'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 3010 } }
            Mock Wait-CorporateProcess { $false }

            Invoke-CorporateItem -Item (New-TestItem @{ path = $installer; arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }) -ConfigDir $TestDrive -WorkDir $workDir |
                Should -BeFalse
            Should -Invoke Start-CorporateProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq $installer -and $Arguments -eq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
            Should -Invoke Wait-CorporateProcess -Times 1 -Exactly -ParameterFilter { $Prompts.Count -eq 0 }
        }

        It 'exe com prompts: repassa as regras e avisa quando o reinício ficou pendente' {
            $installer = Join-Path $TestDrive 'BDEInfoSetup.EXE'; Set-Content -LiteralPath $installer -Value 'x'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 0 } }
            Mock Wait-CorporateProcess { $true }
            $rules = @([pscustomobject] @{ text = 'must be restarted'; button = 'Cancel'; restartPending = $true })

            Invoke-CorporateItem -Item (New-TestItem @{ path = $installer; arguments = '/s'; prompts = $rules }) -ConfigDir $TestDrive -WorkDir $workDir |
                Should -BeTrue
            Should -Invoke Wait-CorporateProcess -Times 1 -Exactly -ParameterFilter { $Prompts.Count -eq 1 -and $Prompts[0].button -eq 'Cancel' }
            ($logged -join "`n") | Should -Match 'reinício foi adiado'
        }

        It 'msi roda o msiexec silencioso, com log e as propriedades do item (ODBC Driver 11)' {
            $package = Join-Path $TestDrive 'msodbcsql-client-11.msi'; Set-Content -LiteralPath $package -Value 'x'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 0 } }
            Mock Wait-CorporateProcess { $false }

            Invoke-CorporateItem -Item (New-TestItem @{ id = 'odbc11'; type = 'msi'; path = $package; arguments = 'IACCEPTMSODBCSQLLICENSETERMS=YES' }) -ConfigDir $TestDrive -WorkDir $workDir |
                Should -BeFalse
            $expectedLog = Join-Path (Split-Path -Parent $testLogFile) 'msi-odbc11.log'
            Should -Invoke Start-CorporateProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -like '*\System32\msiexec.exe' -and
                $Arguments -eq ('/i "{0}" /qn /norestart /l*v "{1}" IACCEPTMSODBCSQLLICENSETERMS=YES' -f $package, $expectedLog)
            }
        }

        It 'msi com exit code 3010: instalado, com reinício pendente' {
            $package = Join-Path $TestDrive 'pacote.msi'; Set-Content -LiteralPath $package -Value 'x'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 3010 } }
            Mock Wait-CorporateProcess { $false }

            Invoke-CorporateItem -Item (New-TestItem @{ type = 'msi'; path = $package }) -ConfigDir $TestDrive -WorkDir $workDir | Should -BeTrue
        }

        It 'msi falha com exit code de erro e indica o log' {
            $package = Join-Path $TestDrive 'pacote.msi'; Set-Content -LiteralPath $package -Value 'x'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 1603 } }
            Mock Wait-CorporateProcess { $false }

            { Invoke-CorporateItem -Item (New-TestItem @{ type = 'msi'; path = $package }) -ConfigDir $TestDrive -WorkDir $workDir } |
                Should -Throw '*exit code 1603*msi-item.log*'
        }

        It 'ODBC Driver 11 no JSON real: \\fs01\Everest30, licença aceita e antes do Everest 3.0' {
            $items = @((Read-CorporateConfig -Path $projectConfig).Items)
            $odbc = $items | Where-Object id -eq 'odbc11'
            $odbc.type      | Should -Be 'msi'
            $odbc.path      | Should -Be '\\fs01\Everest30\msodbcsql-client-11.msi'
            $odbc.arguments | Should -Match 'IACCEPTMSODBCSQLLICENSETERMS=YES'
            $ids = @($items | ForEach-Object { $_.id })
            [array]::IndexOf($ids, 'odbc11') | Should -BeLessThan ([array]::IndexOf($ids, 'everest30'))
        }

        It 'msi com sha256 correto: instala' {
            $package = Join-Path $TestDrive 'FortiClientVPN.msi'; Set-Content -LiteralPath $package -Value 'conteúdo'
            $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 0 } }
            Mock Wait-CorporateProcess { $false }

            { Invoke-CorporateItem -Item (New-TestItem @{ type = 'msi'; path = $package; sha256 = $hash.ToLowerInvariant() }) -ConfigDir $TestDrive -WorkDir $workDir } |
                Should -Not -Throw
            Should -Invoke Start-CorporateProcess -Times 1 -Exactly
        }

        It 'msi com sha256 diferente: não executa o instalador' {
            $package = Join-Path $TestDrive 'FortiClientVPN-trocado.msi'; Set-Content -LiteralPath $package -Value 'outro conteúdo'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 0 } }

            { Invoke-CorporateItem -Item (New-TestItem @{ type = 'msi'; path = $package; sha256 = ('0' * 64) }) -ConfigDir $TestDrive -WorkDir $workDir } |
                Should -Throw '*SHA-256 do instalador não confere*'
            Should -Invoke Start-CorporateProcess -Times 0 -Exactly
        }

        It 'registry grava os valores com o tipo certo e pode ser repetido' {
            # Chave de teste no HKCU, removida no final.
            $key = 'HKCU:\Software\WorkstationProvisioningTests\Sslvpn\Tunnels\Laquila'
            $item = New-TestItem @{ type = 'registry'; key = $key; values = @(
                [pscustomobject] @{ name = 'Server';         value = '201.48.98.109:10443'; kind = 'String' },
                [pscustomobject] @{ name = 'promptusername'; value = 1;                     kind = 'DWord' }
            ) }
            try {
                Invoke-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir
                Invoke-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir

                $saved = Get-Item -LiteralPath $key
                $saved.GetValue('Server')             | Should -Be '201.48.98.109:10443'
                $saved.GetValueKind('promptusername') | Should -Be 'DWord'
                $saved.GetValue('promptusername')     | Should -Be 1
            }
            finally {
                Remove-Item -Path 'HKCU:\Software\WorkstationProvisioningTests' -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'recusa valor de registro sem tipo válido' {
            $file = Join-Path $TestDrive 'registro.json'
            Set-TestConfig -Path $file -Shares @() -Items @(New-TestItem @{ type = 'registry'; key = 'HKCU:\x'; values = @(@{ name = 'a'; value = 1; kind = 'Binario' }) })
            { Read-CorporateConfig -Path $file } | Should -Throw "*'name', 'value' e 'kind'*"
        }

        It 'VPN no JSON real: MSI do pendrive com hash, túnel Laquila em 201.48.98.109 porta 10443, sem senha' {
            $items = @((Read-CorporateConfig -Path $projectConfig).Items)
            $msi = $items | Where-Object id -eq 'forticlient-vpn'
            $msi.path   | Should -BeLike 'C:\ProgramData\WorkstationProvisioning\installers\forticlient\*.msi'
            $msi.sha256 | Should -Match '^[0-9A-F]{64}$'
            $config = $items | Where-Object id -eq 'forticlient-vpn-config'
            $config.key | Should -Be 'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Laquila'
            ($config.values | Where-Object name -eq 'Server').value | Should -Be '201.48.98.109:10443'
            ($config.values | Where-Object name -eq 'promptusername').value | Should -Be 1
            @($config.values | Where-Object { $_.name -match '(?i)DATA1|pass' }).Count | Should -Be 0
        }

        It 'Start-CorporateProcess de verdade: inicia sem o Shell e devolve o exit code' {
            $process = Start-CorporateProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments '/c exit 7'
            $process.WaitForExit()
            $process.ExitCode | Should -Be 7
        }

        It 'exe falha com exit code de erro' {
            $installer = Join-Path $TestDrive 'setup.exe'; Set-Content -LiteralPath $installer -Value 'x'
            Mock Start-CorporateProcess { [pscustomobject] @{ ExitCode = 1603 } }
            Mock Wait-CorporateProcess { $false }

            { Invoke-CorporateItem -Item (New-TestItem @{ path = $installer; arguments = '/s' }) -ConfigDir $TestDrive -WorkDir $workDir } |
                Should -Throw '*exit code 1603*'
        }

        It 'odt copia setup.exe e o XML para a pasta de trabalho e roda de lá (longe do Office antigo do servidor)' {
            $server = Join-Path $TestDrive 'servidor\ODT'
            New-Item -ItemType Directory -Force -Path (Join-Path $server 'Office\Data\16.0.11425.20204') | Out-Null
            $setup = Join-Path $server 'setup.exe'; Set-Content -LiteralPath $setup -Value 'x'
            Set-Content -LiteralPath (Join-Path $TestDrive 'office-odt.xml') -Value '<Configuration />'
            Mock Start-Process { [pscustomobject] @{ ExitCode = 0 } }

            Invoke-CorporateItem -Item (New-TestItem @{ type = 'odt'; path = $setup; odtConfig = 'office-odt.xml' }) -ConfigDir $TestDrive -WorkDir $workDir

            $odtDir = Join-Path $workDir 'odt'
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq (Join-Path $odtDir 'setup.exe') -and $ArgumentList -eq ('/configure "{0}"' -f (Join-Path $odtDir 'configuration.xml'))
            }
            Get-Content -LiteralPath (Join-Path $odtDir 'configuration.xml') | Should -Be '<Configuration />'
            Join-Path $odtDir 'Office' | Should -Not -Exist
        }

        It 'bat roda pelo cmd com a entrada vinda de arquivo vazio (os pause passam sozinhos)' {
            $bat = Join-Path $TestDrive 'Instala.bat'; Set-Content -LiteralPath $bat -Value '@echo off'
            Mock Start-Process { [pscustomobject] @{ ExitCode = 0 } }

            Invoke-CorporateItem -Item (New-TestItem @{ id = 'everest30'; type = 'bat'; path = $bat }) -ConfigDir $TestDrive -WorkDir $workDir

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'cmd.exe' -and ($ArgumentList -join ' ') -eq ('/c "{0}"' -f $bat) -and
                $RedirectStandardInput -like '*empty-input.txt' -and $RedirectStandardOutput -like '*everest30.log'
            }
            (Get-Item -LiteralPath (Join-Path $workDir 'empty-input.txt')).Length | Should -Be 0
        }

        It 'bat de verdade: com a entrada vazia, o pause não trava' {
            $bat = Join-Path $TestDrive 'pausa.bat'
            Set-Content -LiteralPath $bat -Value "@echo off`r`necho antes`r`npause`r`necho depois`r`nexit /b 0" -Encoding ASCII

            { Invoke-CorporateItem -Item (New-TestItem @{ id = 'pausa'; type = 'bat'; path = $bat }) -ConfigDir $TestDrive -WorkDir $workDir } |
                Should -Not -Throw
            Get-Content -LiteralPath (Join-Path $TestDrive 'pausa.log') -Raw | Should -Match 'depois'
        }
    }

    Context 'Install-CorporateItem: um item' {

        It 'pula o item que já está instalado' {
            Mock Test-CorporateItemInstalled { $true }
            Mock Invoke-CorporateItem { }

            (Install-CorporateItem -Item (New-TestItem @{}) -ConfigDir $TestDrive -WorkDir $workDir).Status | Should -Be 'AlreadyInstalled'
            Should -Invoke Invoke-CorporateItem -Times 0 -Exactly
        }

        It 'antivírus sem licença (N): não instala e marca como pulado' {
            Mock Test-CorporateItemInstalled { $false }
            Mock Read-Host { 'N' }
            Mock Invoke-CorporateItem { }

            $result = Install-CorporateItem -Item (New-TestItem @{ confirmLicense = $true }) -ConfigDir $TestDrive -WorkDir $workDir

            $result.Status | Should -Be 'Skipped'
            Should -Invoke Invoke-CorporateItem -Times 0 -Exactly
        }

        It 'antivírus com licença (S): instala' {
            $installed = [ref] $false
            Mock Test-CorporateItemInstalled { $installed.Value }
            Mock Read-Host { 'S' }
            Mock Invoke-CorporateItem { $installed.Value = $true }

            $item = New-TestItem @{ confirmLicense = $true; detect = [pscustomobject] @{ displayName = 'WithSecure*' } }
            (Install-CorporateItem -Item $item -ConfigDir $TestDrive -WorkDir $workDir).Status | Should -Be 'Installed'
        }

        It 'pergunta de novo se a resposta da licença não for S ou N' {
            Mock Test-CorporateItemInstalled { $false }
            $answers = [System.Collections.Generic.Queue[string]]::new([string[]] @('talvez', '', 'S'))
            Mock Read-Host { $answers.Dequeue() }
            Mock Invoke-CorporateItem { }

            [void] (Install-CorporateItem -Item (New-TestItem @{ confirmLicense = $true }) -ConfigDir $TestDrive -WorkDir $workDir)

            Should -Invoke Read-Host -Times 3 -Exactly
        }

        It 'registra o reinício pendente informado pelo instalador' {
            $installed = [ref] $false
            Mock Test-CorporateItemInstalled { $installed.Value }
            Mock Invoke-CorporateItem { $installed.Value = $true; $true }

            $result = Install-CorporateItem -Item (New-TestItem @{ detect = [pscustomobject] @{ path = 'x' } }) -ConfigDir $TestDrive -WorkDir $workDir

            $result.Status           | Should -Be 'Installed'
            $result.IsRestartPending | Should -BeTrue
        }

        It 'marca falha, sem lançar erro, quando o item falha' {
            Mock Test-CorporateItemInstalled { $false }
            Mock Invoke-CorporateItem { throw 'o instalador terminou com exit code 1603' }

            $result = Install-CorporateItem -Item (New-TestItem @{}) -ConfigDir $TestDrive -WorkDir $workDir

            $result.Status  | Should -Be 'Failed'
            $result.Message | Should -BeLike '*1603*'
        }

        It 'marca falha quando termina sem erro, mas não aparece instalado' {
            Mock Test-CorporateItemInstalled { $false }
            Mock Invoke-CorporateItem { }

            $result = Install-CorporateItem -Item (New-TestItem @{ detect = [pscustomobject] @{ displayName = 'X*' } }) -ConfigDir $TestDrive -WorkDir $workDir

            $result.Status  | Should -Be 'Failed'
            $result.Message | Should -BeLike '*não aparece como instalado*'
        }
    }

    Context 'Install-CorporateSoftware: etapa completa' {

        BeforeEach {
            $share = Join-Path $TestDrive 'share'; New-Item -ItemType Directory -Force -Path $share | Out-Null
            $configFile = Join-Path $TestDrive 'corporate-apps.json'
            Mock Get-Credential { New-TestCredential }
            Mock New-SmbMapping { }
            Mock Remove-SmbMapping { }
        }

        It 'retorna $true quando tudo é instalado e desconecta os compartilhamentos' {
            Set-TestConfig -Path $configFile -Shares @($share) -Items @((New-TestItem @{ id = 'a'; name = 'A' }), (New-TestItem @{ id = 'b'; name = 'B' }))
            Mock Install-CorporateItem { [pscustomobject] @{ Name = $Item.name; Required = $true; Status = 'Installed'; Message = '' } }

            Install-CorporateSoftware -ConfigFile $configFile -LogFile $testLogFile -WorkDir $workDir -DomainPrefix 'LAQUILA' | Should -BeTrue
            Should -Invoke Remove-SmbMapping -Times 1 -Exactly -ParameterFilter { $RemotePath -eq $share }
        }

        It 'tenta todos os itens, mostra a falha e retorna $false quando um obrigatório falha' {
            Set-TestConfig -Path $configFile -Shares @($share) -Items @((New-TestItem @{ id = 'a'; name = 'A' }), (New-TestItem @{ id = 'b'; name = 'B' }), (New-TestItem @{ id = 'c'; name = 'C' }))
            Mock Install-CorporateItem {
                $status = if ($Item.id -eq 'b') { 'Failed' } else { 'Installed' }
                [pscustomobject] @{ Name = $Item.name; Required = $true; Status = $status; Message = 'erro simulado' }
            }

            Install-CorporateSoftware -ConfigFile $configFile -LogFile $testLogFile -WorkDir $workDir -DomainPrefix 'LAQUILA' | Should -BeFalse
            Should -Invoke Install-CorporateItem -Times 3 -Exactly
            $logged | Should -Contain '[ERROR]   [FALHA]      B - erro simulado'
        }

        It 'avisa para reiniciar antes da entrega quando um instalador pediu reinício' {
            Set-TestConfig -Path $configFile -Shares @($share) -Items @(New-TestItem @{ id = 'bde'; name = 'BDE 5.2' })
            Mock Install-CorporateItem { [pscustomobject] @{ Name = $Item.name; Required = $true; Status = 'Installed'; Message = ''; IsRestartPending = $true } }

            Install-CorporateSoftware -ConfigFile $configFile -LogFile $testLogFile -WorkDir $workDir -DomainPrefix 'LAQUILA' | Should -BeTrue
            ($logged -join "`n") | Should -Match '\[WARN\] AVISO: reinicie o computador antes de entregá-lo.*BDE 5\.2'
        }

        It 'item pulado (sem licença) não conta como falha' {
            Set-TestConfig -Path $configFile -Shares @($share) -Items @(New-TestItem @{ id = 'av'; name = 'WithSecure' })
            Mock Install-CorporateItem { [pscustomobject] @{ Name = $Item.name; Required = $true; Status = 'Skipped'; Message = 'sem licença' } }

            Install-CorporateSoftware -ConfigFile $configFile -LogFile $testLogFile -WorkDir $workDir -DomainPrefix 'LAQUILA' | Should -BeTrue
            ($logged -join "`n") | Should -Match '\[PULADO\]\s+WithSecure'
        }

        It 'desconecta os compartilhamentos mesmo se um item lançar erro inesperado' {
            Set-TestConfig -Path $configFile -Shares @($share) -Items @(New-TestItem @{})
            Mock Install-CorporateItem { throw 'erro inesperado' }

            { Install-CorporateSoftware -ConfigFile $configFile -LogFile $testLogFile -WorkDir $workDir -DomainPrefix 'LAQUILA' } | Should -Throw
            Should -Invoke Remove-SmbMapping -Times 1 -Exactly
        }
    }
}
