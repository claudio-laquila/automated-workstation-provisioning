# Verificação dos arquivos autounattend.xml

- Análise original: 2026-09-25
- Última revisão: 2026-09-30

Escopo: os 5 arquivos `autounattend.xml` em `Arquivos de autounattend\`. O foco está no arquivo que o CLAUDE.md define como padrão do projeto:

```text
Arquivos de autounattend\Sem interação com partição de disco\GPT\Custom diskpart\No Assertions about the disk\autounattend.xml
```

Neste documento ele é chamado de **XML principal**. O arquivo `Arquivos de autounattend\autounattend.xml` é chamado de **XML da raiz**.

Os números de linha citados correspondem ao estado dos arquivos na data da última revisão.

Legenda de severidade:

- 🔴 **Crítico**: risco de segurança ou de perda de dados, ou impede o objetivo do projeto.
- 🟠 **Alto**: a automação não funciona como o esperado.
- 🟡 **Médio**: inconsistência ou problema de manutenção.
- ⚪ **Baixo**: melhoria recomendada.

Legenda de status:

- ✅ **Resolvido**
- 🔶 **Parcial**
- ❌ **Aberto**

---

## 1. Contas criadas pelos XMLs (verificado em 2026-09-30)

Os 5 arquivos criam **apenas uma conta local**:

| Conta | Grupo | Senha | AutoLogon |
|---|---|---|---|
| `laquila` | Administrators | Temporária de provisionamento, em Base64 (`PlainText=false`) | Sim, 1 logon |

Situação das demais contas:

- **`Admin`**: não é mais criada em nenhum dos 5 arquivos. Foi removida do bloco `<LocalAccount>` e da URL do comentário (`AccountName1=Admin`).
- **`User`**: também foi removida dos 5 arquivos.
- **`Administrator` (conta interna do Windows)**: nenhum XML define `AdministratorPassword`, então ela continua **desabilitada**, que é o padrão do Windows.
- **Scripts do projeto** (`scripts\*.ps1`): nenhum cria contas (`New-LocalUser` / `net user`).

---

## 2. Resumo

| # | Severidade | Problema | Status | Arquivos afetados |
|---|---|---|---|---|
| 1 | 🔴 | Senha da conta administradora gravada no XML | 🔶 Parcial | Todos os 5 |
| 2 | 🔴 | Conta `Admin` (Administrators) com senha vazia | ✅ Resolvido | — |
| 3 | 🔴 | `SELECT DISK=0` fixo, sem nenhuma validação do disco | ❌ Aberto | Os 4 que particionam automaticamente |
| 4 | 🟠 | Nenhuma chamada aos scripts do projeto (`scripts\init.ps1`) | 🔶 Parcial | Os 4 que não são o XML da raiz |
| 5 | 🟠 | Os scripts do pendrive não são copiados para o disco (`$OEM$` ignorado) | ❌ Aberto | Os 4 com `PEMode=Generated` |
| 6 | 🟠 | O AutoLogon vale só para 1 logon, sem retomada após reboot | ❌ Aberto | Todos os 5 |
| 7 | 🟡 | 5 variantes de XML sem definição de qual é a oficial | ❌ Aberto | Pasta inteira |
| 8 | 🟡 | O XML da raiz não particiona o disco automaticamente | ❌ Aberto | XML da raiz |
| 9 | 🟡 | Variantes com Disk Assertions ativas (causa conhecida de falha) | ❌ Aberto | `GPT\` e `GPT\Custom diskpart\` |
| 10 | 🟡 | Variante MBR incompatível com o ambiente alvo (UEFI/GPT) | ❌ Aberto | `MBR\` |
| 11 | 🟡 | Nome do computador aleatório | ❌ Aberto | Todos os 5 |
| 12 | 🟡 | Fuso horário implícito | ❌ Aberto | Todos os 5 |
| 13 | 🟡 | Contas locais extras (`Admin`, `User`) | ✅ Resolvido | — |
| 14 | ⚪ | Erros suprimidos com `-ErrorAction SilentlyContinue` na limpeza | ❌ Aberto | Todos os 5 |
| 15 | ⚪ | Logs de setup deixados em `C:\Windows\Setup\Scripts\` | ❌ Aberto | Todos os 5 |
| 16 | ⚪ | Registro do WinRE na partição Recovery não é verificado | ❌ Aberto | XML principal |
| 17 | ⚪ | `HideOnlineAccountScreens=false` junto com `BypassNRO` | ❌ Aberto | Todos os 5 |

Totais: 2 resolvidos, 2 parciais, 13 abertos.

---

## 3. Histórico de correções

| Data | Item | Alteração |
|---|---|---|
| 2026-09-25 | 2, 13 | Conta `Admin` removida dos 5 arquivos (bloco `<LocalAccount>` + URL do comentário). |
| 2026-09-25 | 4 | XML da raiz passou a chamar `scripts\init.ps1` do pendrive no fim do `First-Logon.ps1` embutido. Criados `scripts\init.ps1` (função `Init`) e `scripts\First-Logon.ps1` (acesso fake). |
| 2026-09-25 | — | O script embutido de primeiro logon foi renomeado de `FirstLogon.ps1` para `First-Logon.ps1` nos 5 arquivos (comando, `File path` e log). |
| 2026-09-30 | 1 | Senha antiga substituída por uma senha temporária de provisionamento, gravada em Base64 com `PlainText=false` em `<LocalAccount>` e `<AutoLogon>`. `AccountPassword0` removido da URL do comentário. |
| 2026-09-30 | 13 | Conta `User` removida dos 5 arquivos. Resta apenas `laquila`. |

---

## 4. Detalhamento dos itens

### 🔴 1. Senha da conta administradora gravada no XML — 🔶 Parcial

**Onde (XML principal):**

- linhas 130–133: senha da conta `laquila` em `<LocalAccount>`;
- linhas 141–144: senha do `<AutoLogon>`.

**Já corrigido:**

- A senha antiga saiu dos 5 arquivos, incluindo a URL do comentário da linha 3.
- No lugar dela entrou uma senha **temporária de provisionamento**, gravada em Base64 (UTF-16LE da senha + sufixo `Password`) com `<PlainText>false</PlainText>`.

**O que ainda é problema:**

- **Base64 não é criptografia.** Quem tiver acesso ao pendrive ou ao repositório recupera a senha temporária em segundos. Enquanto ela não for trocada na máquina, continua dando acesso de administrador.
- O `unattend.xml` copiado para `C:\Windows\Panther\` contém a mesma senha até o primeiro logon (ver item 14).
- **A senha antiga continua no histórico de versões do OneDrive.** Ela deve ser considerada exposta.

**Pendências:**

1. Criar uma etapa no `init.ps1` que troque a senha temporária por uma senha aleatória logo no início do provisionamento.
2. Após o ingresso no domínio, gerenciar a senha da `laquila` com o **Windows LAPS**.
3. Trocar a senha antiga em todas as máquinas que já foram provisionadas com ela.

---

### 🔴 2. Conta `Admin` no grupo Administrators com senha vazia — ✅ Resolvido

A conta não é mais criada em nenhum dos 5 arquivos (ver seção 1).

---

### 🔴 3. `SELECT DISK=0` fixo, sem validação — ❌ Aberto

**Onde (XML principal):** linha 38 (gera `X:\diskpart.txt` com `SELECT DISK=0` e `CLEAN`), executado na linha 54.

**Por que é um problema:**

- A ordem de numeração dos discos não é garantida. Em algumas máquinas o pendrive, ou um segundo disco, pode ser o **Disk 0**.
- `CLEAN` apaga o disco selecionado sem nenhuma confirmação.
- O CLAUDE.md (seção 5) já registra esse risco: "Nunca assumir que Disk 0 será obrigatoriamente o disco correto".

**Correção sugerida:** antes do `diskpart`, fazer no WinPE uma checagem que selecione o disco alvo por propriedades e aborte a instalação se o resultado for ambíguo. Exemplos de critério:

- não ser USB;
- ser o maior disco interno;
- ser NVMe ou SATA.

O WinPE padrão não tem PowerShell. A checagem pode ser feita com `diskpart` + `list disk`, ou com um WinPE customizado que inclua PowerShell.

---

### 🟠 4. Nenhuma chamada aos scripts do projeto — 🔶 Parcial

**Situação atual:**

| Arquivo | Chama `scripts\init.ps1`? |
|---|---|
| XML da raiz | ✅ Sim: linhas 143–152, no fim do `First-Logon.ps1` embutido |
| XML principal e as outras 3 variantes | ❌ Não. O `First-Logon.ps1` embutido (XML principal, linhas 286–315) apenas zera o `AutoLogonCount` e apaga `unattend.xml`, `unattend-original.xml` e `Wifi.xml` |

**Como funciona no XML da raiz:**

1. Procura `scripts\init.ps1` em todas as unidades.
2. Executa o arquivo direto do pendrive, sem copiar para o disco, com `-ExecutionPolicy Bypass`.
3. Registra o exit code no `First-Logon.log`.

**Pendências:**

- Levar a chamada para o XML que for definido como oficial (ver item 7).
- Copiar a automação para `C:\ProgramData\WorkstationProvisioning\` antes de executar. Isso tira a dependência do pendrive depois do primeiro logon e é pré-requisito do item 6.

---

### 🟠 5. Os scripts do pendrive não são copiados para o disco — ❌ Aberto

**Onde (XML principal):** linha 22.

O `pe.cmd` detecta a pasta `$OEM$` e grava o caminho na variável `OEM_FOLDER`, mas **essa variável nunca é usada** nas linhas seguintes. Não existe nenhum `xcopy`/`robocopy` para `W:\`.

**Por que é um problema:** com `PEMode=Generated` o `setup.exe` não é usado. Por isso o mecanismo padrão do Windows que copia `$OEM$\$1` para `C:\` também não roda. Colocar os scripts em `$OEM$` no pendrive **não** resolve.

**Correção sugerida:** uma das opções:

- adicionar ao `pe.cmd` uma cópia de `%OEM_FOLDER%\$1` para `W:\`;
- ou copiar os scripts no primeiro logon, a partir do pendrive (ver item 4).

---

### 🟠 6. O AutoLogon vale só para 1 logon, sem retomada após reboot — ❌ Aberto

**Onde (XML principal):** linha 140 (`<LogonCount>1</LogonCount>`) e linha 289, onde o `First-Logon.ps1` embutido zera o `AutoLogonCount`.

**Por que é um problema:** o fluxo previsto (Windows Update → reboot → Domain Join → reboot → aplicativos) exige vários reboots. Depois do primeiro, a máquina para na tela de login e a automação não continua. Contraria o CLAUDE.md, seções 8 e 20.

**Correção sugerida:** não depender do AutoLogon. No primeiro logon:

- registrar uma **tarefa agendada** (gatilho: inicialização do sistema; conta: SYSTEM) que executa o `init.ps1`;
- controlar o progresso com `C:\ProgramData\WorkstationProvisioning\state.json`;
- remover a tarefa na etapa final de limpeza.

---

### 🟡 7. Cinco variantes de XML sem definição da oficial — ❌ Aberto

| Arquivo | Particionamento | Disk Assertion | Chama `init.ps1` | Situação |
|---|---|---|---|---|
| XML da raiz | Interativo (`PEMode=Default`) | — | Sim | Não é unattended |
| `...\MBR\` | Automático, MBR | Ativa | Não | Incompatível com UEFI |
| `...\GPT\` | Automático, GPT | Ativa | Não | Falha com disco já particionado |
| `...\GPT\Custom diskpart\` | Diskpart customizado | Ativa | Não | Falha com disco já particionado |
| `...\GPT\Custom diskpart\No Assertions about the disk\` | Diskpart customizado | Desativada | Não | **Padrão segundo o CLAUDE.md** |

**Por que é um problema:**

- Há risco de copiar o arquivo errado para o pendrive.
- Cada correção precisa ser repetida nos 5 arquivos.
- Os arquivos já estão divergindo: a chamada ao `init.ps1` só existe no XML da raiz, e o XML padrão não particiona sozinho.

**Correção sugerida:** manter um único `autounattend.xml` oficial, combinando o particionamento do XML principal com a chamada ao `init.ps1`. As outras variantes podem ir para uma pasta `archive\` ou ser removidas.

---

### 🟡 8. O XML da raiz não particiona automaticamente — ❌ Aberto

**Onde:** XML da raiz, com `PEMode=Default` e sem configuração de disco (`DiskConfiguration`).

**Por que é um problema:** o Windows Setup vai parar na tela de escolha de partição, o que contraria o objetivo de instalação totalmente unattended. Hoje ele é o único XML que chama o `init.ps1`, então é o que tem mais chance de ser usado.

**Correção sugerida:** ver item 7.

---

### 🟡 9. Variantes com Disk Assertions ativas — ❌ Aberto

**Onde:** `GPT\autounattend.xml` e `GPT\Custom diskpart\autounattend.xml` (`DiskAssertionMode=Generated`).

**Por que é um problema:** o CLAUDE.md (seção 5) documenta que essa configuração causa `Fatal error: Disk assertion failed` quando o disco já tem partições, que é o caso normal em uma reformatação.

**Correção sugerida:** descartar essas variantes (ver item 7).

---

### 🟡 10. Variante MBR incompatível com o ambiente alvo — ❌ Aberto

**Onde:** `MBR\autounattend.xml` (`PartitionLayout=MBR`).

**Por que é um problema:** o ambiente alvo é UEFI + GPT. O Windows 11 exige UEFI e Secure Boot, que não funcionam em disco MBR.

**Correção sugerida:** descartar a variante, ou documentar para qual caso excepcional ela serve.

---

### 🟡 11. Nome do computador aleatório — ❌ Aberto

**Onde:** todos os arquivos (`ComputerNameMode=Random`). O XML não tem `<ComputerName>`, então o Windows gera um nome no formato `DESKTOP-XXXXXXX`.

**Por que é um problema:** a máquina entra no domínio com um nome fora do padrão. Renomear depois do ingresso exige mais um reboot e credencial de domínio.

**Correção sugerida:** definir o nome no pós-instalação, **antes** do Domain Join, a partir de um padrão configurável (por exemplo, prefixo + número de série do BIOS), em uma etapa própria.

---

### 🟡 12. Fuso horário implícito — ❌ Aberto

**Onde:** todos os arquivos (`TimeZoneMode=Implicit`). O XML não tem `<TimeZone>`.

**Por que é um problema:** o fuso é deduzido pelo idioma e pela região e pode ficar diferente do padrão da empresa. Um relógio errado atrapalha o Kerberos e o ingresso no domínio.

**Correção sugerida:** definir `<TimeZone>E. South America Standard Time</TimeZone>` (ou o fuso correto da empresa) no componente `Microsoft-Windows-Shell-Setup` do passo `specialize`, ou fazer isso no pós-instalação.

---

### 🟡 13. Contas locais extras — ✅ Resolvido

As contas `Admin` e `User` foram removidas dos 5 arquivos. Resta apenas `laquila` (ver seção 1).

**Pendente, relacionado ao item 1:** definir o destino da `laquila` depois do provisionamento: desabilitar, remover ou gerenciar pelo LAPS. Documentar a decisão no README.

---

### ⚪ 14. Erros suprimidos na limpeza — ❌ Aberto

**Onde (XML principal):** linha 296 (`Remove-Item ... -ErrorAction 'SilentlyContinue'`).

**Por que é um problema:** se `C:\Windows\Panther\unattend.xml` não for apagado, a senha temporária do item 1 fica gravada no disco da máquina sem que ninguém perceba. Contraria o CLAUDE.md, seção 19.

**Correção sugerida:** depois da remoção, verificar se os arquivos continuam existindo e registrar o resultado em log.

---

### ⚪ 15. Logs de setup deixados na máquina — ❌ Aberto

**Onde:** `Specialize.log`, `DefaultUser.log`, `First-Logon.log` e `RemovePackages.log`, além dos `.ps1` gerados, todos em `C:\Windows\Setup\Scripts\`.

**Por que é um problema:** os arquivos ficam fora da pasta de logs padrão do projeto (`C:\ProgramData\WorkstationProvisioning\Logs\`) e ninguém os remove.

**Correção sugerida:** na etapa final de limpeza, mover esses logs para a pasta padrão e apagar os `.ps1` temporários.

---

### ⚪ 16. Registro do WinRE não é verificado — ❌ Aberto

**Onde (XML principal):** linhas 38–50 (criação da partição Recovery) e linhas 58–62 (`dism /Apply-Image` + `bcdboot`).

**Por que é um problema:** a imagem é aplicada com `dism`, sem passar pelo `setup.exe`. O XML cria a partição Recovery, mas nada confirma que o Windows Recovery Environment foi registrado nela. Pode ser que ele fique na partição do Windows e a partição Recovery fique vazia. **Isso precisa ser validado em uma máquina de teste.**

**Correção sugerida:** incluir na etapa de validação (`90-validation.ps1`) um `reagentc /info`, verificando se o WinRE está `Enabled` e em qual partição está.

---

### ⚪ 17. `HideOnlineAccountScreens=false` junto com `BypassNRO` — ❌ Aberto

**Onde (XML principal):** linha 150 e linha 237 (`BypassNRO`).

**Por que é um problema:** como o AutoLogon com conta local já está definido, essa tela não deveria aparecer. Mesmo assim, deixar a opção `false` depende de o `BypassNRO` continuar funcionando, e a Microsoft vem restringindo esse mecanismo em builds recentes do Windows 11.

**Correção sugerida:** usar `<HideOnlineAccountScreens>true</HideOnlineAccountScreens>` e testar em cada nova versão da ISO.

---

## 5. Pontos que estão corretos

- O particionamento GPT/UEFI (EFI 300 MB FAT32, MSR 16 MB, Windows, Recovery de ~1000 MB com o GUID e os atributos corretos) segue o layout definido no CLAUDE.md.
- Sem Disk Assertions no XML principal, conforme a decisão documentada.
- O `pe.cmd` interrompe a instalação em erro do `diskpart`, `dism` ou `bcdboot` (`call :fail` com `pause`), em vez de continuar em silêncio.
- `dism /Apply-Image` com `/CheckIntegrity /Verify`.
- O `unattend.xml` é removido do `Panther` no primeiro logon (com a ressalva do item 14).
- Idioma, teclado e região configurados para pt-BR / ABNT2 / Brasil.
- Apenas uma conta local é criada, e a conta interna `Administrator` permanece desabilitada.
- Nos 5 arquivos, o comando de primeiro logon aponta para o script que o próprio XML extrai (`First-Logon.ps1`).

---

## 6. Ordem de correção recomendada

1. **Item 1 (pendências):** trocar a senha antiga nas máquinas já provisionadas e criar a etapa que troca a senha temporária por uma aleatória.
2. **Item 7:** definir um único XML oficial, com o particionamento do XML principal e a chamada ao `init.ps1`, e arquivar os demais.
3. **Item 3:** validar o disco alvo antes do `CLEAN`.
4. **Itens 4, 5 e 6:** copiar os scripts para o disco e criar a tarefa agendada para retomar após reboot.
5. **Itens 11 e 12:** definir nome e fuso horário antes do Domain Join.
6. Demais itens junto com as etapas de hardening, validação e limpeza.
