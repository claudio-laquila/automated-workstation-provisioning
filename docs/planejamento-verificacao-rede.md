# Planejamento: verificação de rede antes do Windows Update

Data: 2026-10-05

Status: **implementado em 2026-10-05**, com as decisões D1 e D2 aprovadas (ver seção 7). Testado em Windows PowerShell 5.1 (seção 9). Teste em VM de ponta a ponta pendente.

## 1. Objetivo

Depois do primeiro logon, o provisionamento deve:

1. verificar se a máquina tem acesso à internet;
2. **aguardar** enquanto não houver conexão, sem avançar para a próxima etapa;
3. quando a conexão existir, iniciar a etapa de Windows Update.

Nesta entrega, a etapa de Windows Update é criada **sem implementação** (apenas a estrutura, para ser preenchida na Fase 3 do roadmap).

## 2. Onde se encaixa na arquitetura

```text
autounattend.xml
  └─ First-Logon.ps1 (embutido)        ← já existe
       └─ scripts\Start-Provisioning.ps1 → Start-Provisioning       ← já existe
            ├─ 1. First-Logon.ps1       ← já existe (acesso fake)
            ├─ 2. Aguardar internet     ← NOVO: Test-InternetConnection em loop
            └─ 3. Install-WindowsUpdates.ps1  ← NOVO: estrutura sem implementação
```

A verificação **não** é uma etapa isolada como as outras, e sim uma **condição de avanço** controlada pelo orquestrador:

- **`Test-InternetConnection`** só responde a pergunta "há internet agora?" e retorna `$true` ou `$false`. Não espera e não decide nada.
- **`Start-Provisioning`** decide o fluxo e repete a verificação até a resposta ser `$true`. Só então chama a próxima etapa.

Assim a função fica simples de testar isoladamente, e a regra "não avançar sem rede" fica em um único lugar, o orquestrador.

## 3. Arquivos

| Arquivo | Ação | Conteúdo |
|---|---|---|
| `scripts\Test-InternetConnection.ps1` | Novo | Função `Test-InternetConnection` → `[bool]`. Executado diretamente, imprime o resultado e sai com exit code 0 (conectado) ou 1 (sem conexão), para troubleshooting. |
| `scripts\Install-WindowsUpdates.ps1` | Novo | Função `Install-WindowsUpdates` sem implementação: registra no log que a etapa está pendente e sai com exit code 0. |
| `scripts\Start-Provisioning.ps1` | Alterado | `Start-Provisioning` passa a ter 3 passos; novas funções `Wait-InternetConnection` (loop de espera), `Show-Step` (cabeçalho e título da janela) e `Show-NetworkHelp` (instruções ao técnico). |
| `autounattend.xml` (raiz e `No Assertions about the disk\`) | Alterado | O `Start-Provisioning.ps1` passa a ser aberto em janela própria e visível (`Start-Process`). |

Os nomes seguem o CLAUDE.md e o `naming.md`: arquivo e função no padrão `Verb-Noun`, com os verbos aprovados `Test`, `Wait` e `Install`.

`Test-InternetConnection` não colide com o cmdlet nativo `Test-NetConnection`.

## 4. `Test-InternetConnection`: como verificar

A verificação tem duas camadas, da mais barata para a mais confiável. Ela para na primeira falha e registra o motivo, o que ajuda o técnico a saber o que conferir:

| # | Verificação | Falha significa |
|---|---|---|
| 1 | Existe adaptador de rede `Up`, com IPv4 e gateway padrão | Sem rede local: cabo desconectado, Wi-Fi não configurado ou DHCP sem resposta |
| 2 | Requisição HTTP a `http://www.msftconnecttest.com/connecttest.txt` retorna exatamente `Microsoft Connect Test` (timeout de 5 s) | Há rede local, mas não há internet: DNS, firewall, proxy ou portal cativo |

**Por que este método:**

- **É o mesmo teste do Windows.** O próprio Windows usa essa URL para decidir se mostra "Sem internet" no ícone de rede (NCSI). Ela é oficial da Microsoft e estável.
- **Não depende de ping.** Ping (ICMP) costuma ser bloqueado em redes corporativas e geraria falsos negativos.
- **Valida o conteúdo da resposta.** Isso detecta portais cativos, que devolvem uma página de login com status 200.
- **Testa o que interessa.** O Windows Update vai precisar alcançar servidores da Microsoft, e é isso que a camada 2 verifica.

**Retorno:** `$true` só se as duas camadas passarem. Nenhuma exceção escapa da função: qualquer erro vira `$false` com o motivo registrado em log, sem ser ignorado em silêncio.

## 5. `Wait-InternetConnection` (no `Start-Provisioning.ps1`): como aguardar

```text
loop:
    se Test-InternetConnection → $true:  registra "Conexão detectada" e sai do loop
    senão: registra o motivo (só quando mudar, ou a cada 5 min)
           aguarda 15 s
           (sem limite de tempo: só sai do loop quando houver conexão)
```

Parâmetros, com valores padrão no código nesta entrega e migração para `config\deployment.json` depois:

| Parâmetro | Padrão | Observação |
|---|---|---|
| `-IntervalSeconds` | `15` | Intervalo entre tentativas |
| `-LogRepeatMinutes` | `5` | Intervalo para repetir no log o mesmo motivo de falha |

**Log sem repetição:** o log registra o motivo apenas quando ele muda, por exemplo de "sem rede local" para "sem internet", e a cada 5 minutos. Isso evita milhares de linhas iguais se a máquina ficar horas sem rede.

## 6. `Install-WindowsUpdates` (estrutura)

- Roda como etapa separada (`Invoke-Stage`), igual ao `First-Logon.ps1`, porque no futuro vai reiniciar a máquina.
- Nesta entrega, apenas registra `[PENDENTE] Windows Update ainda não implementado` e sai com exit code 0.
- A implementação real fica para a Fase 3 do roadmap: procurar, instalar, reiniciar, retomar e repetir.

## 7. Decisões

| # | Decisão | Resultado |
|---|---|---|
| D1 | Sem conexão, aguardar **para sempre** ou desistir após um tempo? | ✅ **Aprovado: aguardar para sempre**, até o técnico conectar o cabo ou fazer login na rede. Não há parâmetro de timeout. |
| D2 | O técnico precisa ver em qual etapa o provisionamento está? | ✅ **Aprovado: janela visível em todas as etapas.** O XML abre o `Start-Provisioning.ps1` com `Start-Process`, sem `-Wait`, para não segurar o primeiro logon. A janela mostra o título "Provisionamento \| Etapa N de 3 - …", um cabeçalho por etapa, instruções em amarelo quando não há rede e barra de progresso com a última tentativa. Ao final, mostra o resultado e aguarda ENTER. |
| D3 | Wi-Fi: o XML não configura nenhuma rede Wi-Fi (`WifiMode=Skip`). | Considerar apenas **cabo** por enquanto e documentar isso. Se Wi-Fi for necessário, avaliar perfil Wi-Fi no XML, que exige cuidado com a senha da rede. |
| D4 | Proxy corporativo: se a internet só funcionar via proxy autenticado, a camada 2 falha. | Confirmar com a infraestrutura se a rede de provisionamento tem saída direta. Se não tiver, tratar o proxy em uma etapa própria. |

## 8. Compatibilidade

- **PowerShell:** o CLAUDE.md define PowerShell 7+, mas uma máquina recém-formatada tem **somente o Windows PowerShell 5.1**. Os scripts desta fase precisam rodar no 5.1. Na prática:
  - `Invoke-WebRequest` precisa de `-UseBasicParsing`;
  - nada de operadores exclusivos do 7, como `??`, `?.` e ternário.
- **Contexto de execução:** a conta `laquila` é administradora. A verificação não exige privilégio elevado.

## 9. Como testar

| Cenário | Esperado |
|---|---|
| Rodar `scripts\Test-InternetConnection.ps1` com internet | Imprime `True`, exit code 0 |
| Mesmo script com o cabo desconectado | Imprime `False`, motivo "sem rede local", exit code 1 |
| VM com rede, mas sem gateway ou DNS válido | `False`, motivo "sem internet" |
| `Start-Provisioning.ps1` iniciado sem rede, cabo conectado após 1 minuto | Log mostra a espera e depois "Conexão detectada". Só então aparece "Iniciando etapa: Install-WindowsUpdates" |
| Rede que exige login (portal cativo) | Continua aguardando, com o motivo "provável portal de login". Depois do login no navegador, avança sozinho. |

Resultados em 2026-10-05, Windows PowerShell 5.1, com o log em pasta temporária:

- **Execução direta com internet:** `True`, exit code 0.
- **Endereço de teste inválido:** retorno `False` (tipo `Boolean`), com o motivo informado.
- **`Start-Provisioning.ps1` com internet:** as 3 etapas na ordem, exit code 0.
- **`Start-Provisioning.ps1` com conexão simulada que falha 2 vezes:** aguardou, registrou o aviso uma única vez e só iniciou a etapa 3 depois da conexão.
- **Ainda não testado:** a janela visível (títulos, cores e ENTER no final). Isso deve ser conferido na VM.

Os testes com e sem cabo devem ser feitos em VM, desconectando o adaptador virtual.

## 10. Riscos e limitações

- **Espera indefinida (D1):** uma máquina sem rede fica aguardando para sempre. Isso é aceitável porque é exatamente o requisito, mas depende de o técnico perceber a situação (D2).
- **Dependência da URL da Microsoft:** se `msftconnecttest.com` estiver bloqueada pelo firewall corporativo, a verificação falha mesmo com internet funcionando. É necessário confirmar com a infraestrutura.
- **Sem retomada após reboot:** como ainda não há tarefa agendada nem `state.json` (itens 6 do relatório de erros e Fase 2 do roadmap), o fluxo não continua sozinho depois de um reboot. A verificação de rede é rápida e idempotente, então pode ser repetida a cada retomada quando isso existir.

## 11. Fora do escopo desta entrega

- Implementação real do Windows Update.
- Configuração de Wi-Fi ou proxy.
- Tarefa agendada / `state.json` para retomar após reboot.
- Leitura dos parâmetros a partir de `config\deployment.json`.
