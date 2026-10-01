# Etapa de primeiro logon.
# Executada pelo init.ps1. A saida (Write-Output) e registrada no deployment.log pelo orquestrador.
# Exit code: 0 = sucesso, 1 = falha.

$ErrorActionPreference = 'Stop'

function Invoke-FakeAccess {
    param(
        [string] $UserName = $env:USERNAME
    )
    # FAKE: nao valida nada de verdade, apenas simula um acesso bem-sucedido.
    # TODO: substituir pela verificacao real de acesso quando ela for definida.
    return $true
}

try {
    Write-Output "Simulando acesso do usuario '$env:USERNAME' (FAKE)..."
    if (-not (Invoke-FakeAccess)) {
        throw 'Acesso negado.'
    }
    Write-Output 'Acesso concedido (FAKE).'
    exit 0
}
catch {
    Write-Output "ERRO: $($_.Exception.Message)"
    exit 1
}
