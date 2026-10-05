# Verifica se a máquina tem acesso à internet.
#
# Uso pelo orquestrador (dot-source):
#   . .\Test-InternetConnection.ps1
#   $isConnected = Test-InternetConnection -InformationVariable info
#
# Uso direto, para troubleshooting:
#   powershell.exe -ExecutionPolicy Bypass -File .\Test-InternetConnection.ps1
#   Imprime o resultado e sai com exit code 0 (conectado) ou 1 (sem conexão).
#
# Compatível com Windows PowerShell 5.1, que é a única versão presente em uma máquina recém-formatada.

function Test-InternetConnection {
    <#
    .SYNOPSIS
    Retorna $true se há acesso à internet e $false caso contrário.

    .DESCRIPTION
    Verifica em duas camadas e para na primeira falha:
      1. Rede local: adaptador ativo com gateway padrão IPv4.
      2. Internet: o mesmo teste usado pelo Windows para o ícone "Sem internet" (NCSI).
         O conteúdo da resposta é validado, o que detecta redes que exigem login (portal cativo).

    O motivo do resultado é enviado ao fluxo de informação; use -InformationVariable para capturá-lo.
    Nenhuma exceção escapa da função: falhas viram $false com o motivo registrado.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $ProbeUri = 'http://www.msftconnecttest.com/connecttest.txt',
        [string] $ExpectedContent = 'Microsoft Connect Test',
        [int] $TimeoutSeconds = 5
    )

    # Camada 1: rede local.
    try {
        $activeConfigurations = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }
    }
    catch {
        Write-Information "falha ao consultar os adaptadores de rede: $($_.Exception.Message)"
        return $false
    }

    if (-not $activeConfigurations) {
        Write-Information 'sem rede local (cabo desconectado, Wi-Fi não configurado ou DHCP sem resposta)'
        return $false
    }

    # Camada 2: internet. Redirecionamento (-MaximumRedirection 0) indica portal de login da rede.
    try {
        $response = Invoke-WebRequest -Uri $ProbeUri -UseBasicParsing -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop
    }
    catch {
        Write-Information "rede local OK, mas sem acesso à internet ou a rede exige login ($($_.Exception.Message))"
        return $false
    }

    if ("$($response.Content)".Trim() -ne $ExpectedContent) {
        Write-Information 'rede local OK, mas a resposta foi diferente da esperada (provável portal de login da rede)'
        return $false
    }

    Write-Information 'rede local e internet OK'
    return $true
}

# Execução direta (não dot-source): imprime o resultado e define o exit code.
if ($MyInvocation.InvocationName -ne '.') {
    $info = $null
    $isConnected = Test-InternetConnection -InformationVariable info
    Write-Output $isConnected
    Write-Output "Motivo: $(($info | Select-Object -Last 1).MessageData)"
    if ($isConnected) { exit 0 } else { exit 1 }
}
