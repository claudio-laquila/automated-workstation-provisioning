# Orquestrador da automacao pos-instalacao.
# Chamado pelo First-Logon.ps1 embutido no autounattend.xml (C:\Windows\Setup\Scripts), a partir do pendrive.
# Cada etapa roda em um processo PowerShell separado; exit code diferente de 0 interrompe o fluxo.

$ErrorActionPreference = 'Stop'

$LogDir  = 'C:\ProgramData\WorkstationProvisioning\Logs'
$LogFile = Join-Path $LogDir 'deployment.log'

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'ERROR')] [string] $Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line
}

function Invoke-Stage {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Script
    )
    $path = Join-Path $PSScriptRoot $Script
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Script da etapa '$Name' nao encontrado: $path"
    }

    Write-Log "Iniciando etapa: $Name"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path | ForEach-Object { Write-Log "  $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "Etapa '$Name' falhou com exit code $LASTEXITCODE"
    }
    Write-Log "Etapa concluida: $Name"
}

function Init {
    Write-Log '==== Inicio do provisionamento ===='

    # Por enquanto apenas a etapa de primeiro logon.
    Invoke-Stage -Name 'First-Logon' -Script 'First-Logon.ps1'

    Write-Log '==== Provisionamento concluido ===='
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

try {
    Init
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
