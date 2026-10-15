# Testes de unidade de scripts\Test-InternetConnection.ps1.
#
# A rede e a internet são SIMULADAS (Mock): nenhum adaptador é consultado e nenhuma requisição é feita.
# Requer Pester 5 ou superior (testado com Pester 6.2 no Windows PowerShell 5.1).
#
# Como rodar, a partir da raiz do projeto:
#   Import-Module Pester -MinimumVersion 5.0
#   Invoke-Pester -Path .\tests\Unit\Test-InternetConnection.Tests.ps1 -Output Detailed

BeforeAll {
    # O script tem guarda de execução: carregado por dot-source, só define a função.
    . (Join-Path $PSScriptRoot '..\..\scripts\Test-InternetConnection.ps1')

    # Simula uma configuração de rede retornada por Get-NetIPConfiguration.
    function New-NetConfiguration {
        param(
            [string] $Gateway = '192.168.0.1',
            [string] $Status  = 'Up'
        )
        $defaultGateway = if ($Gateway) { [pscustomobject] @{ NextHop = $Gateway } } else { $null }
        return [pscustomobject] @{
            IPv4DefaultGateway = $defaultGateway
            NetAdapter         = [pscustomobject] @{ Status = $Status }
        }
    }

    # Simula a resposta de Invoke-WebRequest.
    function New-WebResponse {
        param([string] $Content = 'Microsoft Connect Test')
        return [pscustomobject] @{ StatusCode = 200; Content = $Content }
    }

    # Executa a função e devolve o resultado e o último motivo informado.
    function Invoke-Check {
        param([hashtable] $Parameters = @{})
        $info = $null
        $output = @(Test-InternetConnection @Parameters -InformationVariable info)
        return [pscustomobject] @{
            Output = $output
            Result = $output[-1]
            Reason = ($info | Select-Object -Last 1).MessageData
        }
    }
}

Describe 'Test-InternetConnection' {

    Context 'Camada 1: sem rede local' {

        It 'retorna $false quando não há nenhuma configuração de rede' {
            Mock Get-NetIPConfiguration { @() }
            Mock Invoke-WebRequest { New-WebResponse }

            $check = Invoke-Check

            $check.Result | Should -BeFalse
            $check.Reason | Should -BeLike 'sem rede local*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'retorna $false quando o adaptador está ativo, mas sem gateway padrão' {
            Mock Get-NetIPConfiguration { New-NetConfiguration -Gateway '' }
            Mock Invoke-WebRequest { New-WebResponse }

            $check = Invoke-Check

            $check.Result | Should -BeFalse
            $check.Reason | Should -BeLike 'sem rede local*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'retorna $false quando há gateway, mas o adaptador está desconectado' {
            Mock Get-NetIPConfiguration { New-NetConfiguration -Status 'Disconnected' }
            Mock Invoke-WebRequest { New-WebResponse }

            $check = Invoke-Check

            $check.Result | Should -BeFalse
            $check.Reason | Should -BeLike 'sem rede local*'
        }

        It 'retorna $false e informa o motivo quando a consulta dos adaptadores falha' {
            Mock Get-NetIPConfiguration { throw 'Acesso negado (simulado)' }
            Mock Invoke-WebRequest { New-WebResponse }

            { Invoke-Check } | Should -Not -Throw
            $check = Invoke-Check

            $check.Result | Should -BeFalse
            $check.Reason | Should -BeLike 'falha ao consultar os adaptadores de rede*Acesso negado (simulado)*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'passa para a camada 2 se ao menos um adaptador ativo tiver gateway' {
            Mock Get-NetIPConfiguration {
                @(
                    (New-NetConfiguration -Gateway '' -Status 'Up'),
                    (New-NetConfiguration -Status 'Disconnected'),
                    (New-NetConfiguration -Gateway '10.0.0.1' -Status 'Up')
                )
            }
            Mock Invoke-WebRequest { New-WebResponse }

            (Invoke-Check).Result | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }
    }

    Context 'Camada 2: rede local OK, sem internet' {

        BeforeEach {
            Mock Get-NetIPConfiguration { New-NetConfiguration }
        }

        It 'retorna $false quando a requisição falha (ex.: tempo esgotado)' {
            Mock Invoke-WebRequest { throw 'O tempo limite da operação foi atingido. (simulado)' }

            { Invoke-Check } | Should -Not -Throw
            $check = Invoke-Check

            $check.Result | Should -BeFalse
            $check.Reason | Should -BeLike 'rede local OK, mas sem acesso à internet ou a rede exige login*tempo limite*'
        }

        It 'retorna $false quando a resposta é uma página de login (portal cativo)' {
            Mock Invoke-WebRequest { New-WebResponse -Content '<html><body>Faça login para acessar a rede</body></html>' }

            $check = Invoke-Check

            $check.Result | Should -BeFalse
            $check.Reason | Should -BeLike '*provável portal de login*'
        }

        It 'retorna $false quando a resposta vem vazia' {
            Mock Invoke-WebRequest { New-WebResponse -Content '' }

            (Invoke-Check).Result | Should -BeFalse
        }

        It 'não diferencia maiúsculas e minúsculas no conteúdo esperado' {
            Mock Invoke-WebRequest { New-WebResponse -Content 'microsoft connect test' }

            # O operador -ne do PowerShell não diferencia maiúsculas: o teste documenta esse comportamento.
            (Invoke-Check).Result | Should -BeTrue
        }
    }

    Context 'Conexão OK' {

        BeforeEach {
            Mock Get-NetIPConfiguration { New-NetConfiguration }
        }

        It 'retorna $true e informa "rede local e internet OK"' {
            Mock Invoke-WebRequest { New-WebResponse }

            $check = Invoke-Check

            $check.Result | Should -BeTrue
            $check.Reason | Should -Be 'rede local e internet OK'
        }

        It 'aceita espaços e quebra de linha em volta do conteúdo esperado' {
            Mock Invoke-WebRequest { New-WebResponse -Content "  Microsoft Connect Test`r`n" }

            (Invoke-Check).Result | Should -BeTrue
        }

        It 'usa a URL do teste NCSI da Microsoft, sem seguir redirecionamentos, com tempo limite de 5 s' {
            Mock Invoke-WebRequest { New-WebResponse }

            [void] (Invoke-Check)

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'http://www.msftconnecttest.com/connecttest.txt' -and
                $MaximumRedirection -eq 0 -and
                $TimeoutSec -eq 5 -and
                $UseBasicParsing
            }
        }

        It 'respeita -ProbeUri, -ExpectedContent e -TimeoutSeconds informados' {
            Mock Invoke-WebRequest { New-WebResponse -Content 'OK interno' }

            $check = Invoke-Check -Parameters @{
                ProbeUri        = 'http://teste.local/ok.txt'
                ExpectedContent = 'OK interno'
                TimeoutSeconds  = 2
            }

            $check.Result | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'http://teste.local/ok.txt' -and $TimeoutSec -eq 2
            }
        }
    }

    Context 'Contrato da função' {

        It 'retorna exatamente um valor [bool] no cenário "<_>"' -ForEach @(
            'sem rede local', 'consulta falha', 'requisição falha', 'portal de login', 'conectado'
        ) {
            switch ($_) {
                'sem rede local'   { Mock Get-NetIPConfiguration { @() };                  Mock Invoke-WebRequest { New-WebResponse } }
                'consulta falha'   { Mock Get-NetIPConfiguration { throw 'erro simulado' }; Mock Invoke-WebRequest { New-WebResponse } }
                'requisição falha' { Mock Get-NetIPConfiguration { New-NetConfiguration };  Mock Invoke-WebRequest { throw 'erro simulado' } }
                'portal de login'  { Mock Get-NetIPConfiguration { New-NetConfiguration };  Mock Invoke-WebRequest { New-WebResponse -Content '<html>' } }
                'conectado'        { Mock Get-NetIPConfiguration { New-NetConfiguration };  Mock Invoke-WebRequest { New-WebResponse } }
            }

            $check = Invoke-Check

            $check.Output.Count | Should -Be 1
            $check.Result | Should -BeOfType [bool]
        }

        It 'informa sempre um motivo, mesmo quando retorna $true' {
            Mock Get-NetIPConfiguration { New-NetConfiguration }
            Mock Invoke-WebRequest { New-WebResponse }

            (Invoke-Check).Reason | Should -Not -BeNullOrEmpty
        }
    }
}
