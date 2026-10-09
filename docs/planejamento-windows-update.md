# Planejamento: fase de Windows Update

Data: 2026-10-06

Status: **implementado em 2026-10-08**, com todas as decisões aprovadas (seção 4). Busca real testada em Windows PowerShell 5.1; orquestração testada com a etapa simulada (seção 15). **Instalação real, tarefa agendada e reboot ainda precisam ser testados em VM.**

Corresponde à **Fase 3** do roadmap do CLAUDE.md (seção 24) e depende de partes mínimas da **Fase 2**: estado persistente e retomada após reboot.

---

## 1. Objetivo

Depois que a etapa 2 confirmar a conexão com a internet, instalar **todas as atualizações aplicáveis** do Windows, repetindo o ciclo até não restar nenhuma:

```text
procurar → baixar → instalar → precisa reiniciar? → reiniciar → retomar → procurar de novo …
```

O ciclo termina quando:

- a busca não encontra mais atualizações, **ou**
- é atingido um limite seguro de ciclos.

Durante todo o processo, a janela do provisionamento continua mostrando ao técnico em qual etapa e em qual ciclo a máquina está.

---

## 2. O problema central: reboots

O Windows Update quase sempre exige reiniciar a máquina, às vezes várias vezes. Hoje o provisionamento **não sobrevive a um reboot**:

| Situação atual | Consequência |
|---|---|
| O orquestrador só é iniciado pelo primeiro logon (uma única vez) | Depois do reboot, nada inicia o provisionamento de novo |
| Os scripts rodam direto do pendrive | Se o pendrive for retirado, ou a letra da unidade mudar, os scripts não são encontrados |
| Não existe registro de progresso | O orquestrador não sabe quais etapas já foram concluídas |

Por isso esta fase precisa de **três peças de infraestrutura** antes do Windows Update em si, e todas são reaproveitadas pelas fases seguintes (Domain Join, aplicativos etc.):

1. **Cópia local dos scripts** em `C:\ProgramData\WorkstationProvisioning\scripts\`.
2. **Arquivo de estado** `C:\ProgramData\WorkstationProvisioning\state.json`.
3. **Tarefa agendada** que reabre o orquestrador depois de cada reboot.

---

## 3. Onde se encaixa na arquitetura

```text
autounattend.xml
  └─ First-Logon.ps1 (embutido) → abre D:\scripts\Start-Provisioning.ps1 (pendrive)
                                         │
                                         ▼
Start-Provisioning  (1ª execução)
  ├─ copia scripts\ do pendrive → C:\ProgramData\WorkstationProvisioning\scripts\   ← NOVO
  ├─ registra a tarefa agendada de retomada                                         ← NOVO
  └─ lê state.json e executa a próxima etapa pendente                               ← NOVO
       ├─ 1. Primeiro logon              (já existe)
       ├─ 2. Verificação de internet     (já existe)
       └─ 3. Windows Update              ← IMPLEMENTAR
              ├─ exit 0    → concluído, segue para as próximas fases
              ├─ exit 3010 → precisa reiniciar: grava o estado, reinicia
              └─ exit 1    → falha: interrompe e mostra o erro
                                         │
                       (reboot) ─────────┘
                                         ▼
Tarefa agendada no logon → abre o Start-Provisioning da CÓPIA LOCAL
  └─ lê state.json → pula as etapas concluídas → repete a etapa 2 (rede) → volta à etapa 3
```

**Divisão de responsabilidades**, seguindo o CLAUDE.md (seção 8):

- **`Install-WindowsUpdates.ps1`** só sabe instalar atualizações e **informa** se precisa reiniciar, pelo exit code `3010`. Ele **não reinicia** a máquina.
- **`Start-Provisioning.ps1`** decide o fluxo: grava o estado, mostra a contagem regressiva, reinicia e retoma.

Assim, a regra de reboot fica em um único lugar e as próximas etapas (Domain Join) usam o mesmo mecanismo.

---

## 4. Decisões

| # | Decisão | Resultado (2026-10-06) |
|---|---|---|
| **D1** | Como acessar o Windows Update: (a) **API nativa do Windows** (Windows Update Agent, objeto COM `Microsoft.Update.Session`) ou (b) módulo **PSWindowsUpdate** da PowerShell Gallery | ✅ **(a) API nativa do Windows.** Não depende de nada externo e mantém os filtros sob nosso controle. |
| **D2** | Como o provisionamento volta depois do reboot | ✅ **O técnico faz login** na conta `Laquila` após cada reboot. A tarefa agendada reabre a janela. Sem login automático. |
| **D3** | Incluir **drivers** do Windows Update? | ✅ **Sim.** Configurável para desligar se algum modelo tiver problema. |
| **D4** | Instalar **atualizações de versão** do Windows 11 (ex.: 24H2 → 25H2)? | ✅ **Não. A versão vem da ISO.** Atualizações de versão (categoria *Upgrades*) são sempre excluídas. |
| **D5** | Instalar atualizações **opcionais** e **prévias**? | ✅ **Opcionais: sim. Prévias: não.** Ver o filtro de prévias em 6.2. |
| **D6** | Limite de ciclos e o que fazer depois | ✅ **6 ciclos no máximo.** Ao terminar as atualizações, ou ao atingir o limite com aviso, o provisionamento **é encerrado por enquanto**: a janela mostra "PROVISIONAMENTO CONCLUÍDO" e **continua aberta** até o técnico pressionar ENTER. As próximas etapas (domínio, aplicativos) serão implementadas depois. |

---

## 5. Peças de infraestrutura (Fase 2 mínima)

### 5.1 Cópia local dos scripts

Na primeira execução, o `Start-Provisioning` copia a pasta `scripts\` do pendrive para `C:\ProgramData\WorkstationProvisioning\scripts\`. A tarefa agendada sempre executa essa **cópia local**, então:

- o pendrive pode ser retirado depois da etapa 1;
- uma mudança de letra da unidade (D:, E:…) não quebra a retomada.

### 5.2 `state.json`

Exemplo:

```json
{
    "StartedAt": "2026-10-06T10:15:00",
    "CompletedSteps": [ "First-Logon" ],
    "CurrentStep": "Install-WindowsUpdates",
    "WindowsUpdate": {
        "Cycle": 2,
        "InstalledCount": 14,
        "FailedUpdates": [ "KB5099999" ]
    },
    "LastResult": "RebootRequired",
    "UpdatedAt": "2026-10-06T10:52:00"
}
```

Regras:

- **Gravado antes de qualquer reboot** (CLAUDE.md, seção 20).
- **Verificação de internet:** a etapa 2 **não** é registrada como concluída. Ela roda de novo a cada retomada, porque é rápida e a rede pode ter caído durante o reboot.
- **Arquivo corrompido ou ilegível:** o orquestrador para com erro na tela. Ele não recomeça do zero sem avisar.

### 5.3 Tarefa agendada de retomada

| Propriedade | Valor |
|---|---|
| Nome | `\WorkstationProvisioning\Resume` |
| Gatilho | Logon da conta `Laquila` |
| Privilégio | Mais alto (administrador) |
| Ação | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WorkstationProvisioning\scripts\Start-Provisioning.ps1` |
| Remoção | Na etapa final de limpeza (Fase 9), quando o `state.json` indicar que tudo terminou |

Ela roda **na sessão do técnico**, e não como SYSTEM, para que a janela continue visível (decisão D2 da fase de rede).

Proteção contra duas janelas ao mesmo tempo: se o orquestrador já estiver rodando, por exemplo porque o técnico fez logoff e login sem reboot, a segunda instância avisa e fecha.

---

## 6. `Install-WindowsUpdates`: funcionamento

### 6.1 Pré-requisitos (validados antes de procurar)

| Verificação | Falha |
|---|---|
| Executando como administrador | Erro (exit 1) |
| Serviço Windows Update (`wuauserv`) não desativado; iniciá-lo se estiver parado | Erro (exit 1) |
| Espaço livre em `C:` ≥ 10 GB | Aviso (continua) |

### 6.2 Um ciclo

1. **Procurar** atualizações não instaladas e não ocultas:
   - software e drivers (D3);
   - incluindo as **opcionais** (D5), que a API marca como `BrowseOnly`;
   - excluindo atualizações de versão (D4, categoria *Upgrades*);
   - excluindo **prévias** (D5). A API não tem um campo "prévia": o filtro é feito pelo título, que contém `Preview`, ou `Visualização` / `Prévia` no Windows em português. Esse filtro depende do idioma e precisa ser conferido nos testes;
   - em caso de falha da busca (ex.: erro de rede), tentar de novo até 3 vezes com intervalo de 1 minuto.
2. **Nenhuma encontrada:** exit `0`, Windows Update concluído.
3. **Mostrar a lista** na janela e no log: quantidade, título e KB de cada uma.
4. **Para cada atualização, uma por vez:**
   - aceitar a licença, se houver;
   - baixar;
   - instalar;
   - registrar o resultado.

   A tela mostra `Instalando 3 de 12: KB5xxxxxx – <título>`.
5. **Resultado do ciclo:**
   - alguma atualização pede reboot → exit `3010`;
   - nenhuma pede reboot → procurar de novo, que é o próximo ciclo, sem reiniciar.

**Por que instalar uma por vez**, e não todas juntas:

- **Progresso visível:** a chamada da API que instala em lote não devolve progresso para o PowerShell de forma simples, e a tela ficaria parada por até uma hora.
- **Falha isolada:** uma atualização com problema não derruba as outras, e o resultado de cada uma fica no log.
- **Custo:** fica um pouco mais lento. Algumas atualizações dependem de outras (ex.: pilha de manutenção), mas isso se resolve no ciclo seguinte.

### 6.3 Tratamento de falhas

| Situação | Comportamento |
|---|---|
| Uma atualização falha | Registra o código de erro, continua com as demais e marca a atualização em `FailedUpdates` |
| A mesma atualização falha em 2 ciclos seguidos | Deixa de tentar e registra aviso. Evita repetir a falha até o limite de ciclos. |
| Busca falha 3 vezes | Exit `1`: o provisionamento para com o erro na tela |
| Limite de ciclos atingido (D6) | Aviso no log e na tela, e segue para as próximas fases |

### 6.4 Exit codes

| Código | Significado | O que o orquestrador faz |
|---|---|---|
| `0` | Nada mais a instalar | Marca a etapa como concluída e encerra o provisionamento |
| `2` | Atualizações processadas, sem necessidade de reiniciar | Inicia o próximo ciclo imediatamente |
| `3010` | Precisa reiniciar (inclusive reinicialização já pendente antes do ciclo) | Grava o estado, mostra a contagem regressiva e reinicia |
| `1` | Falha | Interrompe e mostra o erro |

O limite de ciclos (D6) é controlado pelo orquestrador: ao chegar ao 7º ciclo, ele registra um aviso e encerra sem procurar de novo.

`3010` é o código padrão do Windows para "sucesso, reinicialização necessária".

### 6.5 Modo de teste `-SearchOnly`

Parâmetro que **só procura e lista** as atualizações, sem baixar nem instalar. Serve para testar a busca na máquina de desenvolvimento sem alterá-la.

---

## 7. Reboot pelo orquestrador

Quando a etapa devolve `3010`:

1. Grava o `state.json` (ciclo atual, resultado).
2. Mostra na janela:

   ```text
   As atualizações exigem reiniciar o computador.
   O computador será reiniciado em 60 segundos.
   Depois do reinício, faça login na conta Laquila: o provisionamento continua sozinho.
   ```

   O texto vem acompanhado de uma contagem regressiva.
3. Reinicia (`Restart-Computer -Force`).

Após o login, a tarefa reabre a janela com o título `Provisionamento | Etapa 3 de 3 - Windows Update (ciclo 2)`.

---

## 8. Logs

| Arquivo | Conteúdo |
|---|---|
| `Logs\windows-update.log` | **Novo.** Detalhe do Windows Update: busca, lista, resultado de cada atualização (KB, código), necessidade de reboot e resumo de cada ciclo |
| `Logs\deployment.log` | Resumo: início e fim da etapa, ciclo, reboot e resultado final |

Os nomes seguem o CLAUDE.md, seção 17. Os logs não contêm senha nem nenhum dado sensível.

---

## 9. Arquivos

| Arquivo | Ação | Conteúdo |
|---|---|---|
| `scripts\Install-WindowsUpdates.ps1` | Implementar | Seção 6 |
| `scripts\Start-Provisioning.ps1` | Alterar | Cópia local, `state.json`, tarefa agendada, tratamento do exit `3010` e reboot, título com o ciclo |
| `docs\planejamento-windows-update.md` | Este documento | Atualizar com o resultado da implementação |

Configurações (D3, D4, D5, limite de ciclos e tempo da contagem regressiva) ficam como **parâmetros com valor padrão** nesta entrega. A migração para `config\deployment.json` fica para depois, como na fase de rede.

---

## 10. Interação com outras pendências do projeto

- **Troca da senha da conta (item 1 do relatório de erros):** a senha temporária **não pode ser trocada antes do fim** das etapas com reboot. Se ela for trocada antes, o técnico não consegue fazer login para retomar (D2 = login manual). A troca deve ficar na etapa final de limpeza.
- **Robustez da janela (correções propostas e ainda não aplicadas):** com a tarefa agendada, fechar a janela por engano deixa de ser crítico, porque basta fazer logoff e login para retomar. As correções continuam recomendadas.
- **Documentação:** atualizar o item 6 do relatório de erros (retomada após reboot) quando implementado.

---

## 11. Compatibilidade

- **Windows PowerShell 5.1:** a API COM, o `ConvertFrom-Json` / `ConvertTo-Json` e o `Register-ScheduledTask` funcionam nele.
- **Codificação:** UTF-8 **com BOM** nos scripts, por causa dos acentos.
- **Execução:** como `Laquila`, administradora, com privilégio elevado.

---

## 12. Como testar

Os testes devem ser feitos **em VM com snapshot**: as atualizações não podem ser desfeitas facilmente.

| # | Cenário | Esperado |
|---|---|---|
| 1 | `Install-WindowsUpdates.ps1 -SearchOnly` na máquina de desenvolvimento | Lista as atualizações pendentes sem instalar nada |
| 2 | VM recém-instalada, fluxo completo | Vários ciclos com reboot. Após cada login a janela volta no ciclo seguinte e, ao final, a busca retorna 0 |
| 3 | VM já atualizada | Etapa termina no primeiro ciclo (exit 0), sem reboot |
| 4 | Retirar o pendrive depois do 1º reboot | Retomada funciona a partir da cópia local |
| 5 | Fechar a janela no meio da instalação, fazer logoff e login | A tarefa reabre a janela e continua de onde parou |
| 6 | Serviço `wuauserv` desativado | Erro claro na tela, exit 1 |
| 7 | Cabo desconectado durante a busca | Novas tentativas e, se persistir, erro claro |
| 8 | Limite de ciclos reduzido para 1 em uma VM com muitas atualizações | Aviso de limite atingido e o fluxo continua |

---

## 13. Riscos e limitações

- **Tempo:** uma máquina recém-formatada pode levar de **1 a 3 horas** e vários reboots. O técnico precisa fazer login após cada reboot (D2).
- **Atualizações problemáticas:** algumas falham sempre em certos modelos. A regra de "2 falhas seguidas" evita o loop, mas a atualização fica pendente.
- **Drivers opcionais (D3 + D5):** com drivers e opcionais ligados, entram também os **drivers opcionais**, que o Windows normalmente não instala sozinho. Eles podem ser numerosos e, raramente, causar problema em um modelo específico. Por isso drivers e opcionais são configuráveis separadamente.
- **Total de atualizações desconhecido:** só se sabe quantas atualizações há **no ciclo atual**. Depois de um reboot podem surgir outras, que dependiam das anteriores. A tela mostra "N de M neste ciclo" e o total instalado até o momento, nunca um total geral.
- **Windows reiniciando sozinho:** durante a instalação, o próprio Windows pode agendar reboots. A implementação deve evitar que isso aconteça no meio do ciclo, adiando enquanto o provisionamento roda.
- **Erros que dependem do ambiente:** proxy corporativo ou bloqueio dos servidores do Windows Update no firewall fazem a busca falhar. É o mesmo ponto D4 da fase de rede, a confirmar com a infraestrutura.

---

## 14. Implementação (2026-10-08)

| Arquivo | Conteúdo |
|---|---|
| `scripts\Install-WindowsUpdates.ps1` | Um ciclo pela API nativa. Parâmetros `-SearchOnly`, `-ExcludeDrivers` e `-ExcludeOptional`. Falhas por atualização ficam em `windows-update-failures.json`. Detalhe em `Logs\windows-update.log`. |
| `scripts\Start-Provisioning.ps1` | Cópia local dos scripts, `state.json` (gravação atômica), tarefa agendada `\WorkstationProvisioning\Resume`, ciclos com limite de 6, reboot com contagem regressiva de 60 s, instância única (mutex) e encerramento com a janela aberta. |

Arquivos criados na máquina em `C:\ProgramData\WorkstationProvisioning\`:

- `scripts\` (cópia local);
- `state.json`;
- `windows-update-failures.json`;
- `Logs\deployment.log`;
- `Logs\windows-update.log`.

**Para reexecutar o provisionamento do zero** numa máquina de teste: apagar o `state.json`.

---

## 15. Testes realizados (2026-10-08, Windows PowerShell 5.1)

| Teste | Resultado |
|---|---|
| `Install-WindowsUpdates.ps1 -SearchOnly`, real, na máquina de desenvolvimento | ✅ Busca pela API concluída em 38 s, exit 0. Retornou 0 atualizações: a máquina já está atualizada e não usa WSUS. A listagem e os filtros com atualizações reais ficam para a VM. |
| Orquestrador com a etapa de update simulada: ciclo sem reboot (exit 2) e ciclo com reboot (exit 3010) | ✅ Cópia local criada, estado gravado (ciclo 2, `RebootRequired`), reboot chamado, janela fechada sem pausa |
| Retomada a partir da cópia local | ✅ Etapa 1 pulada, rede verificada de novo, ciclo 3 sem atualizações, estado `Completed`, tarefa removida |
| Nova execução após concluído | ✅ "Já foi concluído", nada executado |
| Etapa simulada sempre com exit 2 | ✅ Parou no 6º ciclo, aviso de limite e encerramento |
| `state.json` corrompido | ✅ Erro na tela, exit 1, sem recomeçar do zero |
| Etapa de update com falha (exit 1) | ✅ Interrompido com erro, estado `Running` preservado para retomar |

Nos testes do orquestrador, o registro e a remoção da tarefa agendada e o `Restart-Computer` foram substituídos por versões simuladas, para não alterar a máquina de desenvolvimento.

**Ainda não testado (fazer em VM com snapshot):**

- download e instalação reais;
- filtro de prévias com títulos em português;
- tarefa agendada reabrindo a janela após o login;
- reboot real;
- instância única (mutex);
- aparência da janela.

---

## 16. Fora do escopo

- Atualizações da Microsoft Store e de aplicativos de terceiros.
- Servidor WSUS corporativo: se a empresa usar um, a busca precisará apontar para ele, o que é uma decisão futura.
- Login automático (D2 = alternativa b).
- Parâmetros em `config\deployment.json`.
- Remoção da tarefa agendada e limpeza final (Fase 9).
