# Planejamento: testes automáticos

Data: 2026-10-13

Status: **em implementação.**

| Data | Item | Situação |
|---|---|---|
| 2026-10-14 | T1 | ✅ Pester 6.2.0 instalado e validado no Windows PowerShell 5.1 |
| 2026-10-15 | T2 | 🔶 Aprovada (guarda de execução + `-RootDir`). ✅ Aplicada ao `Install-WindowsUpdates.ps1` em 2026-10-15. ⏳ Pendente no `Start-Provisioning.ps1`. |
| 2026-10-15 | Nível 2: `Test-InternetConnection` | ✅ `tests\Unit\Test-InternetConnection.Tests.ps1`: 19 testes. Prova de eficácia: numa cópia com 2 defeitos inseridos de propósito, 3 testes falharam como esperado. |
| 2026-10-15 | Nível 2: Windows Update | ✅ `tests\Unit\Install-WindowsUpdates.Tests.ps1`: 54 testes (carregamento, rótulo, as 5 regras de seleção, contagem de falhas, busca com novas tentativas, pré-requisitos e o ciclo completo com a API simulada). Prova de eficácia: 4 defeitos inseridos de propósito, todos detectados. **Os testes encontraram 2 defeitos reais**, corrigidos no script (ver o planejamento do Windows Update). |
| 2026-10-15 | Nível 2: aplicativos | ✅ `tests\Unit\Install-Applications.Tests.ps1`: 46 testes (lista de aplicativos, incluindo o `apps.json` real; detecção; validação por hash e assinatura; download com novas tentativas; reserva do pendrive; execução MSI/EXE; ocupado 1618; etapa completa). Prova de eficácia: 4 defeitos inseridos, todos detectados. O script já nasceu com a T2 (guarda + `-RootDir`). |
| 2026-10-16 | Nível 2: bloqueio de reinício | ✅ `tests\Unit\AutoRestartPolicy.Tests.ps1`: 8 testes. Usa uma chave de teste em `HKCU` (a política real em `HKLM` não é tocada): bloquear, restaurar sem configuração prévia, preservar valores existentes, devolver o valor original, não sobrescrever o backup nas retomadas. |
| 2026-10-16 | Nível 2: energia | ✅ `tests\Unit\PowerPolicy.Tests.ps1`: 11 testes, com o `powercfg` simulado (o plano de energia real não é alterado): leitura do texto em português, backup do original, zerar os tempos de suspender, hibernar e desligar a tela e desligar a hibernação, não sobrescrever o backup nas retomadas, restauração, inclusive de backup antigo sem o tempo da tela. |
| — | T3 a T5 e demais testes | Aguardando decisão |

Corresponde à **Fase 10 (Testes)** do roadmap do CLAUDE.md, antecipada para proteger o que já existe: autounattend, verificação de rede, Windows Update e login automático.

---

## 1. Objetivo

Hoje cada mudança é testada com scripts improvisados em pastas temporárias. Esses testes não ficam no projeto, não podem ser repetidos com facilidade e dependem de alguém lembrar de rodá-los.

O objetivo é ter testes que:

- ficam **versionados** junto com o código (`tests\`);
- rodam com **um comando** (`Invoke-Pester`);
- **nunca alteram a máquina de quem roda**: nada de instalar atualizações, reiniciar, gravar no LSA ou ativar login automático no computador de desenvolvimento;
- avisam quando uma mudança quebra algo que funcionava (regressão).

---

## 2. O que dá e o que não dá para testar automaticamente

| Parte | Automatizável? | Como |
|---|---|---|
| Sintaxe, codificação (BOM) e padrão de nomes dos scripts | ✅ Totalmente | Análise estática (nível 1) |
| Regras dos `autounattend.xml` (contas, senha, disco, chamada ao orquestrador) | ✅ Totalmente | Análise estática (nível 1) |
| Lógica das funções: filtro de atualizações, leitura do arquivo de senha, estado, verificação de rede | ✅ Totalmente | Testes de unidade com simulação (nível 2) |
| Fluxo do orquestrador: etapas, ciclos, reboot, retomada, erros | ✅ Com simulação | Testes de integração (nível 3) |
| Gravação real no LSA, registro do Winlogon, tarefa agendada, QuickEdit, bloqueio de suspensão | 🟡 Em ambiente descartável | Windows Sandbox ou runner do GitHub (nível 4) |
| Instalação completa: particionamento, reboots reais, Windows Update real, login automático real | 🟡 Lento e complexo | VM Hyper-V automatizada (nível 5) |
| Hardware real: NVMe/SATA, pendrive como Disk 0, Ventoy, Wi-Fi, drivers de fabricante | ❌ | Checklist manual (seção 6) |

---

## 3. Níveis de teste propostos

### Nível 1 — Análise estática (segundos)

| Verificação | Ferramenta |
|---|---|
| Erros de sintaxe em todos os `.ps1` | Parser do PowerShell |
| Boas práticas e **verbos aprovados** (`Verb-Noun`) | **PSScriptAnalyzer** (módulo oficial da Microsoft) |
| Todos os `.ps1` com acentos estão em **UTF-8 com BOM** (acentos no PowerShell 5.1) | Teste próprio |
| Variáveis em `camelCase`, parâmetros em `PascalCase` (`naming.md`) | Regras do PSScriptAnalyzer + teste próprio |
| **XMLs:** bem formados; **só a conta `Laquila`**; `PlainText=false`; **nenhuma senha legível**; o comando do primeiro logon aponta para o arquivo que o XML extrai; o XML oficial chama `scripts\Start-Provisioning.ps1` e **não** tem Disk Assertions | Teste próprio |
| `config\autologon.txt` **nunca** versionado | Teste próprio (`git check-ignore`) |

### Nível 2 — Testes de unidade (segundos)

Cada função é testada isoladamente. O que acessa o sistema é **simulado** (*mock*): rede, API do Windows Update, registro, LSA.

| Componente | Exemplos de casos |
|---|---|
| `Test-InternetConnection` | sem adaptador → `$false` e motivo "sem rede local"; HTTP com conteúdo errado → "portal de login"; tudo OK → `$true`; o retorno é sempre `Boolean` |
| `Select-InstallableUpdate` | as 5 regras da seção 6.2.1 do planejamento do Windows Update: versão do Windows, prévia (em inglês e português), opcional, "pode pedir interação" (software × driver), 2 falhas |
| Contagem de falhas do Windows Update | grava, lê e incrementa o `windows-update-failures.json` |
| `Read-AutoLogonCredentialFile` | Base64 válido, inválido, arquivo vazio |
| Estado (`Get/Save-ProvisioningState`, `Complete-Step`) | arquivo inexistente → estado novo; corrompido → erro claro; campo faltando → erro; gravação atômica |
| `Wait-InternetConnection` | aguarda enquanto não houver rede; registra o motivo só quando ele muda |

### Nível 3 — Integração do orquestrador (1–2 minutos)

Roda o `Start-Provisioning.ps1` **inteiro**, numa pasta temporária, com as etapas e as ações perigosas simuladas: Windows Update, reboot, tarefa agendada e login automático. É a formalização dos testes feitos manualmente até agora.

| Cenário | Esperado |
|---|---|
| Primeira execução a partir do "pendrive" | Copia os scripts, cria o `state.json`, registra a tarefa |
| Ciclo sem reboot (exit 2) e com reboot (exit 3010) | Grava o ciclo, ativa o login automático, chama o reboot, fecha sem pausa |
| Retomada a partir da cópia local | Pula o que já foi feito e continua do ciclo seguinte |
| Limite de 6 ciclos | Aviso e encerramento |
| Sem `autologon.txt` | Aviso; tela orienta login manual |
| Erro na etapa | Interrompe, desliga o login automático, mantém o estado |
| `state.json` corrompido | Erro na tela, sem recomeçar do zero |
| Já concluído | "Nada a fazer" |

### Nível 4 — Funções do Windows em ambiente descartável (minutos)

As funções que alteram o sistema **de verdade** não podem rodar na máquina de desenvolvimento, mas podem rodar num Windows que é **descartado depois**:

- gravar e ler segredo no LSA;
- configurar e desligar o login automático no registro;
- remover a senha em texto puro do registro;
- validar senha de uma conta local criada só para o teste;
- registrar e remover a tarefa agendada;
- bloquear a suspensão;
- desativar o QuickEdit.

Duas opções de ambiente:

| Opção | Como funciona | Prós | Contras |
|---|---|---|---|
| **4a. Windows Sandbox** | Windows descartável que já vem no Windows 11 Pro (recurso opcional) | Local, gratuito, abre em segundos, sempre limpo | Não reinicia (não testa o login automático real); não tem Windows Update; precisa habilitar o recurso |
| **4b. Runner Windows do GitHub Actions** | Máquina virtual descartável do GitHub, criada a cada execução | Roda sozinho a cada push; é administrador; descartada ao final | Consome minutos do plano do GitHub (Windows conta em dobro); Windows Server em vez de Windows 11 |

### Nível 5 — Ponta a ponta em VM Hyper-V (1–3 horas)

Instalação **completa**, sem intervenção, numa VM criada por script:

1. Gera uma ISO com o `autounattend.xml` oficial e a pasta `scripts\`.
2. Cria uma VM Hyper-V (UEFI, Secure Boot, TPM virtual) a partir de um modelo.
3. Inicia a VM e espera: particionamento → instalação → primeiro logon → rede → ciclos do Windows Update com reboots reais → login automático real.
4. Coleta o resultado de dentro da VM pelo **PowerShell Direct** (sem rede):
   - `state.json` com `Completed`;
   - logs;
   - `AutoAdminLogon = 0` e **sem `DefaultPassword`**;
   - tarefa removida;
   - nenhuma atualização pendente.
5. Apaga a VM, ou volta ao checkpoint inicial.

| Prós | Contras |
|---|---|
| Testa de verdade o que hoje só é testado à mão | Exige **Hyper-V** habilitado e uma ISO do Windows 11 no host de testes |
| Pega problemas de reboot, login automático e Windows Update reais | Demora de 1 a 3 horas; precisa de internet |
| Pode rodar à noite, sem ninguém acompanhar | Montar a primeira versão dá mais trabalho que os outros níveis |

O **Disk 0 da VM** é um disco virtual, então não há risco de apagar o disco do host.

---

## 4. Estrutura proposta

```text
tests\
├── Static\
│   ├── Scripts.Tests.ps1          ← sintaxe, BOM, PSScriptAnalyzer, nomes
│   └── Autounattend.Tests.ps1     ← regras dos XMLs
├── Unit\
│   ├── Test-InternetConnection.Tests.ps1
│   ├── Install-WindowsUpdates.Tests.ps1
│   ├── AutoLogon.Tests.ps1
│   └── ProvisioningState.Tests.ps1
├── Integration\
│   └── Start-Provisioning.Tests.ps1   ← fluxo completo com simulações
├── Sandbox\                          ← nível 4a (se aprovado)
│   ├── Run-SandboxTests.ps1
│   └── SystemFunctions.Tests.ps1
├── EndToEnd\                         ← nível 5 (se aprovado)
│   └── Invoke-VmProvisioningTest.ps1
└── Invoke-Tests.ps1                  ← roda os níveis 1 a 3 com um comando
```

Comando para o desenvolvedor, antes de cada commit:

```powershell
.\tests\Invoke-Tests.ps1
```

---

## 5. Mudança necessária nos scripts: torná-los testáveis

Hoje o `Start-Provisioning.ps1` e o `Install-WindowsUpdates.ps1` **executam o fluxo assim que são carregados**. Por isso os testes feitos até agora precisaram de truques: copiar o script e trocar texto, ou extrair funções do código. Isso é frágil.

Duas mudanças pequenas resolvem, sem alterar o comportamento em produção:

| Mudança | Como | Efeito |
|---|---|---|
| **Guarda de execução** | O fluxo principal só roda quando o script é executado, e não quando é carregado por dot-source. É o mesmo padrão já usado no `Test-InternetConnection.ps1`. | Os testes carregam as funções sem disparar o provisionamento |
| **Pasta raiz configurável** | Parâmetro opcional `-RootDir` (padrão `C:\ProgramData\WorkstationProvisioning`) | Os testes usam uma pasta temporária sem trocar texto no script |

---

## 6. O que continua manual (checklist por versão)

Antes de usar uma nova versão em produção, testar em **máquina real** pelo menos:

- [ ] boot pelo **Ventoy** e aplicação do XML;
- [ ] disco **NVMe** e disco **SATA**;
- [ ] máquina com **segundo disco**, e confirmar que o disco certo foi apagado;
- [ ] notebook com **Wi-Fi**: conexão manual pelo técnico;
- [ ] rede com **página de login**;
- [ ] **fechar a tampa** durante o Windows Update (a suspensão continua acontecendo; comportamento esperado);
- [ ] drivers de fabricante (Intel, Realtek etc.) instalados pelo Windows Update.

Os itens 1 a 15 de teste da Fase 10 do CLAUDE.md que não forem cobertos pelos níveis automáticos entram nesta lista.

---

## 7. Decisões para escolher

| # | Decisão | Opções | Recomendação |
|---|---|---|---|
| **T1** | Ferramenta de testes | (a) **Pester 5 ou superior**, instalado da PowerShell Gallery na máquina de desenvolvimento; (b) Pester 3.4, que já vem no Windows, mas é antigo | ✅ **Decidido (2026-10-14): Pester 6.2.0**, instalado com `Install-Module Pester -MinimumVersion 5.0 -Scope AllUsers -Force -SkipPublisherCheck`, em `C:\Program Files\WindowsPowerShell\Modules`. O escopo `AllUsers` foi usado porque a pasta Documentos do usuário fica no OneDrive. A compatibilidade com o Windows PowerShell 5.1 foi testada: `Should`, `Mock`, `TestDrive` e `Should -Throw` funcionam. O 3.4 continua instalado, mas os testes exigem a versão 5 ou superior (`Import-Module Pester -MinimumVersion 5.0`). O Pester **não** vai para o pendrive: é usado só no desenvolvimento. |
| **T2** | Tornar os scripts testáveis (seção 5) | Sim / Não | **Sim.** Sem isso, os testes de unidade e integração continuam dependendo de truques frágeis. |
| **T3** | Quais níveis implementar agora | 1, 2, 3, 4a, 4b, 5 | **Agora: 1, 2 e 3** (rápidos, locais, protegem a lógica). **Depois:** 4a (Sandbox), e 5 (VM) quando houver um host com Hyper-V. |
| **T4** | Rodar os testes automaticamente no **GitHub** a cada push (4b + níveis 1 a 3) | Sim / Não / Depois | **Depois.** Primeiro estabilizar os testes locais. Ao ativar, conferir o consumo de minutos do plano. Os caminhos longos exigem configurar `core.longpaths` no runner. |
| **T5** | Rodar os testes **antes de cada commit** automaticamente (hook do Git) | Sim / Não | **Não, por enquanto.** O hook obriga todos que clonarem o repositório a ter o Pester. Começar com o comando manual `Invoke-Tests.ps1`. |

---

## 8. Observações sobre o Pester 6

- **Simulação com filtro sem simulação padrão dá erro.** Se um comando tem só `Mock` com `-ParameterFilter` e a chamada não bate com nenhum filtro, o Pester 6 lança erro em vez de usar o comando real, como fazia o Pester 5.
  - Quando o teste precisar do comando real para as outras chamadas, crie uma simulação padrão que chame o cmdlet pelo objeto `CmdletInfo`: `$ExecutionContext.InvokeCommand.GetCmdlet('Microsoft.PowerShell.Utility\New-Object')`.
  - Pelo nome, mesmo qualificado com o módulo, o Pester 6 intercepta de novo e entra em loop.
  - Nas funções auxiliares dos testes, prefira `[Tipo]::new()` a `New-Object`.
- **Avisos falsos do analisador.** Variáveis atribuídas no teste para serem lidas pelas funções do script (ex.: `$SearchOnly`) geram o aviso `PSUseDeclaredVarsMoreThanAssignments`. Ele é suprimido no início do arquivo de teste, com comentário explicando o motivo.

---

## 9. Riscos e limitações

- **Simulação não é a realidade:** os níveis 1 a 3 garantem a lógica, não o comportamento do Windows. Por isso os níveis 4, 5 e o checklist manual continuam necessários.
- **Testes que alteram o sistema** (nível 4) **nunca** devem rodar na máquina de desenvolvimento. O `Invoke-Tests.ps1` não os inclui; eles só rodam no Sandbox, no runner ou na VM.
- **Manutenção:** cada funcionalidade nova precisará de testes novos. Recomendo tornar isso regra do projeto (CLAUDE.md, seção 25).
- **Windows Update real** (nível 5) muda conforme o mês: o número de atualizações e de reboots varia. O teste deve verificar o **resultado** (concluído, nada pendente), não quantidades fixas.
