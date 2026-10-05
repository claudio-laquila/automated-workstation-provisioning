# Etapa de Windows Update.
# Executada pelo Start-Provisioning.ps1 somente depois que Test-InternetConnection confirmar acesso à internet.
# A saída (Write-Output) é exibida na janela do provisionamento e registrada no deployment.log pelo orquestrador.
# Exit code: 0 = sucesso, 1 = falha.
#
# PENDENTE (Fase 3 do roadmap): procurar atualizações, instalar, detectar necessidade de reboot,
# reiniciar, retomar e repetir até não haver mais atualizações aplicáveis.

$ErrorActionPreference = 'Stop'

function Install-WindowsUpdates {
    # TODO: implementar na Fase 3 do roadmap.
    Write-Output '[PENDENTE] Windows Update ainda não implementado. Nenhuma atualização foi instalada.'
}

try {
    Install-WindowsUpdates
    exit 0
}
catch {
    Write-Output "ERRO: $($_.Exception.Message)"
    exit 1
}
