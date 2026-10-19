# Bloqueio do reinício automático do Windows Update durante o provisionamento.
# Carregado pelo Start-Provisioning.ps1 (dot-source).
#
# O QUE MUDA
#   Política HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoRebootWithLoggedOnUsers = 1
#   (DWORD). Com um usuário conectado, o Windows Update não reinicia a máquina por conta própria.
#
# POR QUÊ
#   No teste de 2026-10-16, o Windows Update reiniciou a máquina sozinho à meia-noite
#   (MoUsoCoreWorker.exe / TrustedInstaller.exe), no meio do provisionamento.
#   Os reboots devem ficar com o orquestrador, que grava o progresso antes de reiniciar.
#
# IMPACTO
#   Só os reinícios AUTOMÁTICOS do Windows Update são bloqueados. As atualizações continuam sendo
#   instaladas, e os reboots pedidos pelo orquestrador acontecem normalmente.
#
# COMO REVERTER
#   Automático: Restore-WindowsUpdateAutoRestart, chamado ao concluir o provisionamento, restaura o valor
#   original guardado no arquivo de backup.
#   Manual, se o provisionamento for abandonado (PowerShell como administrador):
#     Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoRebootWithLoggedOnUsers
#
# Exige execução como administrador. Compatível com Windows PowerShell 5.1.

$autoRestartPolicyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$autoRestartPolicyValue = 'NoAutoRebootWithLoggedOnUsers'

function Disable-WindowsUpdateAutoRestart {
    # Bloqueia o reinício automático. Guarda a configuração original só na primeira vez,
    # para que as retomadas não sobrescrevam o original com o valor do próprio provisionamento.
    param([Parameter(Mandatory)] [string] $BackupFile)

    if (-not (Test-Path -LiteralPath $BackupFile)) {
        $isKeyExisting = Test-Path -LiteralPath $autoRestartPolicyKey
        $currentValue = $null
        if ($isKeyExisting) {
            $currentValue = (Get-ItemProperty -LiteralPath $autoRestartPolicyKey).PSObject.Properties[$autoRestartPolicyValue]
        }
        $backup = [pscustomobject] @{
            KeyExisted   = $isKeyExisting
            ValueExisted = $null -ne $currentValue
            Value        = if ($null -ne $currentValue) { [int] $currentValue.Value } else { $null }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BackupFile) | Out-Null
        $backup | ConvertTo-Json | Set-Content -LiteralPath $BackupFile -Encoding UTF8
    }

    if (-not (Test-Path -LiteralPath $autoRestartPolicyKey)) {
        New-Item -Path $autoRestartPolicyKey -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $autoRestartPolicyKey -Name $autoRestartPolicyValue -Value 1 -PropertyType DWord -Force | Out-Null
}

function Restore-WindowsUpdateAutoRestart {
    # Restaura a configuração original. Retorna $true se havia algo a restaurar.
    param([Parameter(Mandatory)] [string] $BackupFile)

    if (-not (Test-Path -LiteralPath $BackupFile)) {
        return $false
    }
    $backup = Get-Content -LiteralPath $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($backup.ValueExisted) {
        if (-not (Test-Path -LiteralPath $autoRestartPolicyKey)) {
            New-Item -Path $autoRestartPolicyKey -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $autoRestartPolicyKey -Name $autoRestartPolicyValue -Value ([int] $backup.Value) -PropertyType DWord -Force | Out-Null
    }
    elseif (Test-Path -LiteralPath $autoRestartPolicyKey) {
        $key = Get-Item -LiteralPath $autoRestartPolicyKey
        if ($key.GetValueNames() -contains $autoRestartPolicyValue) {
            Remove-ItemProperty -LiteralPath $autoRestartPolicyKey -Name $autoRestartPolicyValue
        }
        # Remove a chave AU só se ela foi criada pelo provisionamento e ficou vazia.
        $key = Get-Item -LiteralPath $autoRestartPolicyKey
        if (-not $backup.KeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
            Remove-Item -LiteralPath $autoRestartPolicyKey
        }
    }

    Remove-Item -LiteralPath $BackupFile
    return $true
}
