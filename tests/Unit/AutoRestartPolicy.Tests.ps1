# Testes de unidade de scripts\AutoRestartPolicy.ps1.
#
# A política REAL do Windows (HKLM\SOFTWARE\Policies\...) NÃO é alterada: os testes redirecionam as funções
# para uma chave de teste do usuário (HKCU:\Software\WorkstationProvisioningTests), apagada ao final.
# Requer Pester 5 ou superior (testado com Pester 6.2 no Windows PowerShell 5.1).
#
# Como rodar, a partir da raiz do projeto:
#   Import-Module Pester -MinimumVersion 5.0
#   Invoke-Pester -Path .\tests\Unit\AutoRestartPolicy.Tests.ps1 -Output Detailed

# $autoRestartPolicyKey é reatribuída para que as funções do script a leiam pelo escopo.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Describe 'AutoRestartPolicy.ps1' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\scripts\AutoRestartPolicy.ps1')

        $testRootKey = 'HKCU:\Software\WorkstationProvisioningTests'
        # Redireciona as funções para a chave de teste.
        $autoRestartPolicyKey = Join-Path $testRootKey 'WindowsUpdate\AU'

        function Get-PolicyValue {
            if (-not (Test-Path -LiteralPath $autoRestartPolicyKey)) { return $null }
            $property = (Get-ItemProperty -LiteralPath $autoRestartPolicyKey).PSObject.Properties[$autoRestartPolicyValue]
            if ($property) { return $property.Value }
            return $null
        }

        function Reset-TestKey {
            if (Test-Path -LiteralPath $testRootKey) {
                Remove-Item -LiteralPath $testRootKey -Recurse
            }
        }
    }

    AfterAll {
        Reset-TestKey
    }

    BeforeEach {
        Reset-TestKey
        $backupFile = Join-Path $TestDrive 'auto-restart-policy-backup.json'
        if (Test-Path -LiteralPath $backupFile) { Remove-Item -LiteralPath $backupFile }
    }

    It 'nunca aponta para a política real nos testes' {
        $autoRestartPolicyKey | Should -BeLike 'HKCU:\Software\WorkstationProvisioningTests\*'
    }

    It 'bloqueia o reinício automático (valor 1) quando não havia configuração' {
        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile

        Get-PolicyValue | Should -Be 1
        $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
        $backup.KeyExisted   | Should -BeFalse
        $backup.ValueExisted | Should -BeFalse
    }

    It 'ao restaurar, remove o valor e a chave criados pelo provisionamento' {
        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile

        Restore-WindowsUpdateAutoRestart -BackupFile $backupFile | Should -BeTrue

        $autoRestartPolicyKey | Should -Not -Exist
        $backupFile | Should -Not -Exist
    }

    It 'ao restaurar, mantém a chave e os outros valores que já existiam' {
        New-Item -Path $autoRestartPolicyKey -Force | Out-Null
        New-ItemProperty -LiteralPath $autoRestartPolicyKey -Name 'OutraPolitica' -Value 5 -PropertyType DWord | Out-Null

        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile
        [void] (Restore-WindowsUpdateAutoRestart -BackupFile $backupFile)

        $autoRestartPolicyKey | Should -Exist
        Get-PolicyValue | Should -BeNullOrEmpty
        (Get-ItemProperty -LiteralPath $autoRestartPolicyKey).OutraPolitica | Should -Be 5
    }

    It 'ao restaurar, devolve o valor original que já existia (ex.: 0)' {
        New-Item -Path $autoRestartPolicyKey -Force | Out-Null
        New-ItemProperty -LiteralPath $autoRestartPolicyKey -Name $autoRestartPolicyValue -Value 0 -PropertyType DWord | Out-Null

        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile
        Get-PolicyValue | Should -Be 1

        [void] (Restore-WindowsUpdateAutoRestart -BackupFile $backupFile)
        Get-PolicyValue | Should -Be 0
    }

    It 'nas retomadas, não sobrescreve a configuração original guardada' {
        New-Item -Path $autoRestartPolicyKey -Force | Out-Null
        New-ItemProperty -LiteralPath $autoRestartPolicyKey -Name $autoRestartPolicyValue -Value 0 -PropertyType DWord | Out-Null

        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile   # 1ª execução: guarda o original (0)
        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile   # retomada: o valor atual já é 1
        [void] (Restore-WindowsUpdateAutoRestart -BackupFile $backupFile)

        Get-PolicyValue | Should -Be 0
    }

    It 'sem backup, não restaura nada e retorna $false' {
        New-Item -Path $autoRestartPolicyKey -Force | Out-Null
        New-ItemProperty -LiteralPath $autoRestartPolicyKey -Name $autoRestartPolicyValue -Value 1 -PropertyType DWord | Out-Null

        Restore-WindowsUpdateAutoRestart -BackupFile $backupFile | Should -BeFalse
        Get-PolicyValue | Should -Be 1
    }

    It 'não apaga a chave criada pelo provisionamento se outra coisa foi colocada nela depois' {
        Disable-WindowsUpdateAutoRestart -BackupFile $backupFile
        New-Item -Path (Join-Path $autoRestartPolicyKey 'SubChave') -Force | Out-Null

        [void] (Restore-WindowsUpdateAutoRestart -BackupFile $backupFile)

        $autoRestartPolicyKey | Should -Exist
        Get-PolicyValue | Should -BeNullOrEmpty
    }
}
