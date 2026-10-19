# Desativação da hibernação, da suspensão e do desligamento da tela durante o provisionamento.
# Carregado pelo Start-Provisioning.ps1 (dot-source).
#
# O QUE MUDA (plano de energia ativo)
#   - Hibernação desligada: powercfg /hibernate off. Também desliga a Inicialização Rápida, que depende dela.
#   - Tempo para hibernar = nunca (tomada e bateria).
#   - Tempo para suspender = nunca (tomada e bateria).
#   - Tempo para desligar a tela = nunca (tomada e bateria), para o técnico sempre ver a janela.
#
# POR QUÊ
#   No teste de 2026-10-08, a máquina hibernou no meio do Windows Update. O bloqueio feito pela janela do
#   provisionamento (SetThreadExecutionState) só vale enquanto ela está aberta: não cobre a tela de login
#   depois de um reboot nem a janela fechada.
#
# IMPACTO
#   Durante o provisionamento, a máquina não hiberna, não suspende e não apaga a tela por inatividade.
#   NÃO altera a ação de fechar a tampa do notebook: fechar a tampa continua suspendendo.
#
# COMO REVERTER
#   Automático: Restore-ProvisioningPowerPolicy, chamado ao concluir o provisionamento, devolve os valores
#   originais guardados no arquivo de backup.
#   Manual, se o provisionamento for abandonado (PowerShell como administrador):
#     powercfg /hibernate on
#     powercfg /change standby-timeout-ac 30   (e os demais tempos desejados, em minutos:
#     standby-timeout-dc, hibernate-timeout-ac/dc, monitor-timeout-ac/dc)
#
# Exige execução como administrador. Compatível com Windows PowerShell 5.1.

$sleepSubgroupGuid   = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # SUB_SLEEP
$standbyIdleGuid     = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'   # STANDBYIDLE (suspender após, em segundos)
$hibernateIdleGuid   = '9d7815a6-7ee4-497e-8888-515a05f02364'   # HIBERNATEIDLE (hibernar após, em segundos)
$videoSubgroupGuid   = '7516b95f-f776-4464-8c53-06167f40cc99'   # SUB_VIDEO
$videoIdleGuid       = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'   # VIDEOIDLE (desligar a tela após, em segundos)
$powerControlKey     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'

function Invoke-PowerCfg {
    # Executa o powercfg e lança erro se ele falhar.
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $output = & powercfg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('powercfg {0} falhou (exit code {1}): {2}' -f ($Arguments -join ' '), $LASTEXITCODE, ($output -join ' '))
    }
    return , @($output)
}

function Get-PowerTimeout {
    # Retorna os valores atuais (segundos) de uma configuração do plano de energia: AC (tomada) e DC (bateria).
    # O texto do powercfg é traduzido; por isso lê só os números: os dois últimos são o valor atual em AC e em DC.
    param(
        [Parameter(Mandatory)] [string] $SettingGuid,
        [string] $SubgroupGuid = $sleepSubgroupGuid
    )
    $output = Invoke-PowerCfg -Arguments @('/query', 'SCHEME_CURRENT', $SubgroupGuid, $SettingGuid)
    $values = @([regex]::Matches(($output -join "`n"), '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt64($_.Value, 16) })
    if ($values.Count -lt 2) {
        throw "Não foi possível ler a configuração de energia $SettingGuid."
    }
    return [pscustomobject] @{ Ac = $values[-2]; Dc = $values[-1] }
}

function Set-PowerTimeout {
    param(
        [Parameter(Mandatory)] [string] $SettingGuid,
        [Parameter(Mandatory)] [long] $AcSeconds,
        [Parameter(Mandatory)] [long] $DcSeconds,
        [string] $SubgroupGuid = $sleepSubgroupGuid
    )
    [void] (Invoke-PowerCfg -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $SubgroupGuid, $SettingGuid, $AcSeconds))
    [void] (Invoke-PowerCfg -Arguments @('/setdcvalueindex', 'SCHEME_CURRENT', $SubgroupGuid, $SettingGuid, $DcSeconds))
}

function Test-HibernationEnabled {
    $power = Get-ItemProperty -LiteralPath $powerControlKey
    return $null -ne $power.PSObject.Properties['HibernateEnabled'] -and [int] $power.HibernateEnabled -eq 1
}

function Disable-ProvisioningPowerSaving {
    # Desliga hibernação, suspensão e desligamento da tela por inatividade. Guarda a configuração original
    # só na primeira vez, para que as retomadas não sobrescrevam o original com os valores do provisionamento.
    param([Parameter(Mandatory)] [string] $BackupFile)

    if (-not (Test-Path -LiteralPath $BackupFile)) {
        $standby   = Get-PowerTimeout -SettingGuid $standbyIdleGuid
        $hibernate = Get-PowerTimeout -SettingGuid $hibernateIdleGuid
        $video     = Get-PowerTimeout -SettingGuid $videoIdleGuid -SubgroupGuid $videoSubgroupGuid
        $backup = [pscustomobject] @{
            HibernationEnabled = Test-HibernationEnabled
            StandbyAc          = $standby.Ac
            StandbyDc          = $standby.Dc
            HibernateAc        = $hibernate.Ac
            HibernateDc        = $hibernate.Dc
            VideoAc            = $video.Ac
            VideoDc            = $video.Dc
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BackupFile) | Out-Null
        $backup | ConvertTo-Json | Set-Content -LiteralPath $BackupFile -Encoding UTF8
    }

    # 0 = nunca.
    Set-PowerTimeout -SettingGuid $standbyIdleGuid   -AcSeconds 0 -DcSeconds 0
    Set-PowerTimeout -SettingGuid $hibernateIdleGuid -AcSeconds 0 -DcSeconds 0
    Set-PowerTimeout -SettingGuid $videoIdleGuid     -AcSeconds 0 -DcSeconds 0 -SubgroupGuid $videoSubgroupGuid
    [void] (Invoke-PowerCfg -Arguments @('/setactive', 'SCHEME_CURRENT'))
    [void] (Invoke-PowerCfg -Arguments @('/hibernate', 'off'))
}

function Restore-ProvisioningPowerPolicy {
    # Devolve a configuração original. Retorna $true se havia algo a restaurar.
    param([Parameter(Mandatory)] [string] $BackupFile)

    if (-not (Test-Path -LiteralPath $BackupFile)) {
        return $false
    }
    $backup = Get-Content -LiteralPath $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($backup.HibernationEnabled) {
        [void] (Invoke-PowerCfg -Arguments @('/hibernate', 'on'))
    }
    Set-PowerTimeout -SettingGuid $standbyIdleGuid   -AcSeconds $backup.StandbyAc   -DcSeconds $backup.StandbyDc
    Set-PowerTimeout -SettingGuid $hibernateIdleGuid -AcSeconds $backup.HibernateAc -DcSeconds $backup.HibernateDc
    # Backups da versão anterior não têm o tempo da tela: nesse caso ele não é restaurado.
    if ($null -ne $backup.VideoAc -and $null -ne $backup.VideoDc) {
        Set-PowerTimeout -SettingGuid $videoIdleGuid -AcSeconds $backup.VideoAc -DcSeconds $backup.VideoDc -SubgroupGuid $videoSubgroupGuid
    }
    [void] (Invoke-PowerCfg -Arguments @('/setactive', 'SCHEME_CURRENT'))

    Remove-Item -LiteralPath $BackupFile
    return $true
}
