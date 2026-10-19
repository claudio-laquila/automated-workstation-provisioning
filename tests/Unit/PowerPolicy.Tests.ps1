# Testes de unidade de scripts\PowerPolicy.ps1.
#
# O powercfg é SIMULADO (Mock de Invoke-PowerCfg): o plano de energia da máquina não é alterado.
# A simulação usa o texto em português que o powercfg devolve no Windows 11 pt-BR.
# Requer Pester 5 ou superior (testado com Pester 6.2 no Windows PowerShell 5.1).
#
# Como rodar, a partir da raiz do projeto:
#   Import-Module Pester -MinimumVersion 5.0
#   Invoke-Pester -Path .\tests\Unit\PowerPolicy.Tests.ps1 -Output Detailed

Describe 'PowerPolicy.ps1' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\scripts\PowerPolicy.ps1')

        # Resposta do "powercfg /query" (pt-BR) para um valor em AC (tomada) e DC (bateria), em segundos.
        function New-QueryOutput {
            param([long] $AcSeconds, [long] $DcSeconds)
            return , @(
                'GUID da Configuração de Energia: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Suspender após)',
                '  Configuração Mínima Possível: 0x00000000',
                '  Configuração Máxima Possível: 0xffffffff',
                '  Incremento de Configurações Possíveis: 0x00000001',
                '  Unidades de Configurações Possíveis: Segundos',
                ('Índice de Configurações de Correntes Alternadas Atuais: 0x{0:x8}' -f $AcSeconds),
                ('Índice de Configurações de Correntes Contínuas Atuais: 0x{0:x8}' -f $DcSeconds)
            )
        }

        # Plano de energia simulado: suspender após 30 min (tomada) / 15 min (bateria); hibernar após 180 / 60 min;
        # desligar a tela após 10 / 5 min.
        function Use-FakePowerCfg {
            Mock Invoke-PowerCfg {
                if ($Arguments[0] -eq '/query' -and $Arguments[3] -eq $standbyIdleGuid)   { return New-QueryOutput -AcSeconds 1800  -DcSeconds 900 }
                if ($Arguments[0] -eq '/query' -and $Arguments[3] -eq $hibernateIdleGuid) { return New-QueryOutput -AcSeconds 10800 -DcSeconds 3600 }
                if ($Arguments[0] -eq '/query' -and $Arguments[2] -eq $videoSubgroupGuid -and $Arguments[3] -eq $videoIdleGuid) {
                    return New-QueryOutput -AcSeconds 600 -DcSeconds 300
                }
                return , @()
            }
        }

        function Test-PowerCfgCall {
            # Confere se o powercfg foi chamado com exatamente estes argumentos.
            param([string] $Expected, [int] $Times = 1)
            Should -Invoke Invoke-PowerCfg -Times $Times -Exactly -ParameterFilter { ($Arguments -join ' ') -eq $Expected }
        }
    }

    BeforeEach {
        $backupFile = Join-Path $TestDrive 'power-policy-backup.json'
        if (Test-Path -LiteralPath $backupFile) { Remove-Item -LiteralPath $backupFile }
        Mock Test-HibernationEnabled { $true }
    }

    Context 'Invoke-PowerCfg (powercfg real, sem alterar nada)' {

        It 'lança erro quando o powercfg falha' {
            # Argumento inválido: o powercfg real apenas recusa, sem alterar o plano de energia.
            { Invoke-PowerCfg -Arguments @('/argumento-que-nao-existe') } | Should -Throw '*powercfg /argumento-que-nao-existe falhou*'
        }
    }

    Context 'Leitura do plano de energia' {

        BeforeEach { Use-FakePowerCfg }

        It 'lê os valores de tomada (AC) e bateria (DC) no texto em português do powercfg' {
            $value = Get-PowerTimeout -SettingGuid $standbyIdleGuid

            $value.Ac | Should -Be 1800
            $value.Dc | Should -Be 900
        }

        It 'lê o tempo de desligar a tela no grupo Vídeo' {
            $value = Get-PowerTimeout -SettingGuid $videoIdleGuid -SubgroupGuid $videoSubgroupGuid

            $value.Ac | Should -Be 600
            $value.Dc | Should -Be 300
        }

        It 'falha com erro claro se não encontrar os valores' {
            Mock Invoke-PowerCfg { , @('saída inesperada') }

            { Get-PowerTimeout -SettingGuid $standbyIdleGuid } | Should -Throw '*Não foi possível ler a configuração de energia*'
        }
    }

    Context 'Disable-ProvisioningPowerSaving' {

        BeforeEach { Use-FakePowerCfg }

        It 'guarda a configuração original antes de alterar' {
            Disable-ProvisioningPowerSaving -BackupFile $backupFile

            $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
            $backup.HibernationEnabled | Should -BeTrue
            $backup.StandbyAc   | Should -Be 1800
            $backup.StandbyDc   | Should -Be 900
            $backup.HibernateAc | Should -Be 10800
            $backup.HibernateDc | Should -Be 3600
            $backup.VideoAc     | Should -Be 600
            $backup.VideoDc     | Should -Be 300
        }

        It 'zera os tempos de suspender, hibernar e desligar a tela (tomada e bateria), aplica e desliga a hibernação' {
            Disable-ProvisioningPowerSaving -BackupFile $backupFile

            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $sleepSubgroupGuid $standbyIdleGuid 0"
            Test-PowerCfgCall "/setdcvalueindex SCHEME_CURRENT $sleepSubgroupGuid $standbyIdleGuid 0"
            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $sleepSubgroupGuid $hibernateIdleGuid 0"
            Test-PowerCfgCall "/setdcvalueindex SCHEME_CURRENT $sleepSubgroupGuid $hibernateIdleGuid 0"
            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $videoSubgroupGuid $videoIdleGuid 0"
            Test-PowerCfgCall "/setdcvalueindex SCHEME_CURRENT $videoSubgroupGuid $videoIdleGuid 0"
            Test-PowerCfgCall '/setactive SCHEME_CURRENT'
            Test-PowerCfgCall '/hibernate off'
        }

        It 'nas retomadas, não sobrescreve a configuração original guardada' {
            Disable-ProvisioningPowerSaving -BackupFile $backupFile

            # Na retomada, o plano já está com os valores do provisionamento (0) e a hibernação desligada.
            Mock Invoke-PowerCfg { if ($Arguments[0] -eq '/query') { return New-QueryOutput -AcSeconds 0 -DcSeconds 0 }; , @() }
            Mock Test-HibernationEnabled { $false }
            Disable-ProvisioningPowerSaving -BackupFile $backupFile

            $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
            $backup.StandbyAc          | Should -Be 1800
            $backup.HibernationEnabled | Should -BeTrue
        }
    }

    Context 'Restore-ProvisioningPowerPolicy' {

        BeforeEach { Use-FakePowerCfg }

        It 'devolve os tempos originais, religa a hibernação e apaga o backup' {
            Disable-ProvisioningPowerSaving -BackupFile $backupFile

            Restore-ProvisioningPowerPolicy -BackupFile $backupFile | Should -BeTrue

            Test-PowerCfgCall '/hibernate on'
            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $sleepSubgroupGuid $standbyIdleGuid 1800"
            Test-PowerCfgCall "/setdcvalueindex SCHEME_CURRENT $sleepSubgroupGuid $standbyIdleGuid 900"
            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $sleepSubgroupGuid $hibernateIdleGuid 10800"
            Test-PowerCfgCall "/setdcvalueindex SCHEME_CURRENT $sleepSubgroupGuid $hibernateIdleGuid 3600"
            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $videoSubgroupGuid $videoIdleGuid 600"
            Test-PowerCfgCall "/setdcvalueindex SCHEME_CURRENT $videoSubgroupGuid $videoIdleGuid 300"
            $backupFile | Should -Not -Exist
        }

        It 'restaura um backup da versão anterior (sem o tempo da tela) sem erro' {
            [pscustomobject] @{ HibernationEnabled = $true; StandbyAc = 1800; StandbyDc = 900; HibernateAc = 10800; HibernateDc = 3600 } |
                ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8

            { Restore-ProvisioningPowerPolicy -BackupFile $backupFile } | Should -Not -Throw

            Test-PowerCfgCall "/setacvalueindex SCHEME_CURRENT $sleepSubgroupGuid $standbyIdleGuid 1800"
            Should -Invoke Invoke-PowerCfg -Times 0 -Exactly -ParameterFilter { ($Arguments -join ' ') -like "*$videoIdleGuid*" }
        }

        It 'não religa a hibernação se ela já estava desligada antes do provisionamento' {
            Mock Test-HibernationEnabled { $false }
            Disable-ProvisioningPowerSaving -BackupFile $backupFile

            [void] (Restore-ProvisioningPowerPolicy -BackupFile $backupFile)

            Test-PowerCfgCall '/hibernate on' -Times 0
        }

        It 'sem backup, não altera nada e retorna $false' {
            Restore-ProvisioningPowerPolicy -BackupFile $backupFile | Should -BeFalse

            Should -Invoke Invoke-PowerCfg -Times 0 -Exactly
        }
    }
}
