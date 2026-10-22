# Planejamento: softwares corporativos (Office, antivírus, Everest)

Data: 2026-10-19

Status: **etapas 6 (OU) e 7 (softwares corporativos) implementadas em 2026-10-19.** Pendente: testar em VM os parâmetros silenciosos e os nomes de detecção (seção 7).

## Etapa 7 implementada: softwares corporativos

- **Código:** `scripts\Install-CorporateSoftware.ps1` (funções), chamado pelo `Start-Provisioning.ps1` na etapa 7, dentro da janela do provisionamento.
- **Lista e ordem:** `config\corporate-apps.json`. Para acrescentar um software, basta incluir um item (tipos: `odt`, `exe`, `msi`, `bat`, `copy-folder`, `copy-file`, `shortcuts`, `registry`). `exe` e `msi` aceitam `sha256` (o instalador só roda se o hash conferir).
- **Credencial:** a caixa de credencial do Windows abre já com `LAQUILA\`. A senha fica só na memória, é usada para conectar aos compartilhamentos (`New-SmbMapping`, não persistente) e as conexões são removidas no final. Três tentativas; a senha nunca vai para o log.
- **Ordem:** Office (ODT) → WithSecure (pergunta da licença S/N) → ODBC Driver 11 (Client 11) → Everest 3.0 (`.bat`, com os `pause` respondidos por entrada vazia) → `C:\everest1` → `ntwdblib.dll` em `SysWOW64` → BDE Update 5.2 → BDE 5.1.1 Full → `IDAPI32.CFG` → atalhos **Everest** (`MEU.exe`) e **EverestLite** (`MeuLite.exe`) em `C:\Users\Public\Desktop` → FortiClient VPN → túnel Laquila.
- **Já instalado:** cada item tem `detect` (caminho ou nome em Programas e Recursos) e é pulado se já existir. `IDAPI32.CFG` e os atalhos são sempre refeitos (sem efeito colateral).
- **Falhas:** todos os itens são tentados; o resumo mostra `[OK]`, `[JÁ HAVIA]`, `[PULADO]` e `[FALHA]`. Se um item obrigatório falhar, a etapa termina com erro e, ao executar de novo, só o que faltou é refeito. WithSecure sem licença (N) fica `[PULADO]` e não bloqueia.
- **Logs:** `Logs\corporate-software.log` (detalhes) e `Logs\everest30.log` (saída do `.bat`).
- **Testes:** `tests\Unit\Install-CorporateSoftware.Tests.ps1` (68 testes, sem servidor e sem instalar nada).

### Correções após o primeiro teste em máquina (2026-10-19)

| Problema observado | Causa | Correção |
|---|---|---|
| O ODT instalou um Office muito antigo | Ao lado do `setup.exe` do servidor existe `Office\Data\16.0.11425.20204` (cópia de 2019). Sem `SourcePath`, o ODT usa os arquivos da própria pasta antes do download da Microsoft. | O `setup.exe` e o XML são copiados para `C:\ProgramData\WorkstationProvisioning\Temp\odt\` e executados de lá: o ODT baixa a versão atual. |
| Depois de reiniciar, o Office foi instalado de novo | A detecção por nome (`Microsoft 365*`) não reconhecia o Office antigo. | Detecção por `WINWORD.EXE` com **versão mínima** `16.0.17000.0`: um Office antigo conta como "não instalado" e o ODT o atualiza. |
| BDE 5.2: "This system must be restarted… OK / Cancel" | O instalador Wise pede reinício mesmo no modo `/s` e não tem opção para evitar isso. | `cancelRestartPrompt: true`: enquanto o instalador roda, a etapa procura esse pedido nas janelas dele e clica em **Cancel** sozinha. No final, o resumo avisa para reiniciar antes da entrega. |
| Clicar OK no BDE 5.2 reiniciou no meio da etapa; ao voltar, tudo foi refeito | Consequência dos dois itens anteriores. | Resolvido pelas duas correções acima. |
| WithSecure pediu clique | ⏳ A opção `--silent` existe no instalador (confirmado nos textos internos, junto com `--nocopy`, `--voucher` etc.). Falta saber qual janela apareceu. | Ver o segundo teste, abaixo. |
| BDE 5.1.1 pediu confirmação das etapas | ⏳ O `setup.exe` é Inno Setup 5.1.7, que aceita `/VERYSILENT`. Pode ser um segundo instalador, ou uma mensagem, aberto pelo Inno. | Ver o segundo teste, abaixo. |

### Correções após o segundo teste (2026-10-21, capturas de tela do técnico)

| Problema observado | Causa | Correção |
|---|---|---|
| WithSecure: "Abrir Arquivo - Aviso de Segurança / Deseja executar este arquivo?" (Origem `\\marketing\...`) | Aviso do **Windows**, e não do instalador: executáveis abertos pelo Shell (`Start-Process`) a partir de uma pasta de rede fora da zona Intranet pedem confirmação. Numa máquina recém-instalada, `\\marketing` não é reconhecido como Intranet. | Os instaladores `exe` são iniciados **sem o Shell** (`Start-CorporateProcess`, `UseShellExecute = false`), o que não passa pelo aviso. Não muda nenhuma configuração de segurança da máquina. |
| BDE 5.1.1: janelas "Borland Database Engine Installation/Upgrade" (pasta, OK), "There is not enough space on drive C:. Install anyway?" (Yes, duas vezes) e "The specified directory does not exist. Create it?" (Yes) | O Inno Setup roda em silêncio, mas abre o instalador antigo da Borland, que mostra essas janelas. O aviso de espaço é um falso alarme de programa antigo, que não lê corretamente discos grandes. | Regras `prompts` no `corporate-apps.json`: a etapa responde sozinha OK/Yes, como orientado pelo técnico. **Só toca em janelas do instalador e dos processos que ele abriu.** O mesmo mecanismo substitui o antigo `cancelRestartPrompt` do BDE 5.2. |
| BDE 5.1.1: "terminou sem erro, mas não aparece como instalado" | Aceitando a pasta sugerida, o BDE é instalado em `C:\Program Files (x86)\Common Files\Borland Shared\BDE`. A detecção só olhava `C:\Program Files (x86)\Borland\Common Files\BDE` (a pasta das máquinas instaladas manualmente, ex.: 102-1772). | A detecção aceita as duas pastas. |
| `IDAPI32.CFG` copiado para uma pasta que o BDE não usa | O destino era fixo (`Borland\Common Files\BDE`); o BDE lê a configuração do caminho registrado em `HKLM\SOFTWARE\WOW6432Node\Borland\Database Engine\CONFIGFILE01`. | `destinationRegistry`: o arquivo é copiado para o caminho de `CONFIGFILE01`. Se o BDE não estiver instalado, o item falha com mensagem clara. |

**Pasta do BDE (decidido em 2026-10-21): igual às máquinas manuais.** Na primeira janela, a etapa digita `C:\Program Files (x86)\Borland\Common Files\BDE` antes do OK (`setText` na regra). A detecção continua aceitando também `Common Files\Borland Shared\BDE`, por causa das máquinas já testadas, e o `IDAPI32.CFG` segue a pasta registrada pelo BDE.

Nomes de detecção confirmados em uma máquina instalada manualmente: `WithSecure™ Elements Agent`, `BDE Information Utility` e `Microsoft 365 Apps para Pequenos e Médios negócios - pt-br` (16.0.20430).

## Etapa 6 implementada: local no AD (OU)

**Por que existe:** quando o computador ingressa no domínio, o AD o coloca no contêiner padrão `Computers`, que **não recebe GPOs**. O procedimento da empresa move o computador para a OU certa **antes** de instalar os softwares, para que ele receba as políticas corporativas.

**Destino:** `OU=Computadores novos,OU=LAQUILA,DC=laquila,DC=local`, confirmado no AD em 2026-10-19. Fica em `config\domain.json` (`targetOu`, `targetOuName`).

**Funcionamento** (`Confirm-ComputerOu`, no `Start-Provisioning.ps1`), com conferência automática (opção 2):

1. Lê a localização do computador no registro: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Distinguished-Name`. O Windows grava esse valor a cada processamento das políticas, e a leitura não exige credencial.
2. Se não estiver na OU de destino, atualiza as políticas (`gpupdate /target:computer /force`, respondendo "não" a um eventual pedido de reinício) e lê de novo.
3. Se ainda não estiver na OU, mostra as instruções: no DC01, "Usuários e Computadores do AD" → localizar o computador → Mover → LAQUILA → Computadores novos. Depois **aguarda o ENTER** do técnico.
4. Após o ENTER, atualiza as políticas e confere de novo. Repete até o computador estar **diretamente** na OU de destino.

**Testado (2026-10-19):**

- comparação com dados reais (este computador está em `OU=Computadores,OU=Informatica,OU=LAQUILA,…`) → corretamente "fora" de Computadores novos;
- não confunde sub-OU; local vazio = fora;
- orquestrador com a localização simulada: em `Computers` → instruções → ENTER sem mover → aviso de novo → ENTER depois de mover → concluído.

**Falta testar em VM:** a mudança real no DC01 e a atualização do `Distinguished-Name` pelo `gpupdate`.

---

Etapa seguinte ao ingresso no domínio (etapa 5).

---

## 1. Procedimento manual atual (referência)

1. Mudar o computador de local (OU) no **DC01**. Só depois instalar:
2. **Office:** `\\marketing\softwares\Office 2016\Instaladores\OfficeSetup.exe`
3. **Antivírus (WithSecure/F-Secure):**
   - verificar se já existe licença para a máquina no portal WithSecure;
   - instalar `\\marketing\softwares\Antivirus\F-Secure\ElementsAgentInstaller[…E03G-ATRT].exe`.
4. **Everest 30:** executar como administrador `\\fs01\Everest30\Instala_everest30.bat`.
5. **Everest 2.11:**
   - copiar `\\marketing\softwares\BDE\everest1` para `C:\`;
   - copiar `BDE\DLLS\ntwdblib.dll` para `C:\Windows\SysWOW64`;
   - instalar `Client BDE Update v 5.2` e `Client BDE … v 5.1.1 Full`.
6. **Client 11** (informado em 2026-10-21): instalar `\\fs01\Everest30\msodbcsql-client-11.msi` (**Microsoft ODBC Driver 11 for SQL Server** 12.2.5543.11, x64). Na etapa, o item `odbc11` (tipo `msi`) roda antes do Everest 3.0 com `/qn` e `IACCEPTMSODBCSQLLICENSETERMS=YES` (aceite da licença exigido pelo pacote). O log fica em `Logs\msi-odbc11.log`.
7. **VPN (FortiClient)** (informado em 2026-10-21): executar o `FortiClientVPNOnlineInstaller` mais novo (`\\marketing\softwares\fotigate`) e configurar no aplicativo IP `201.48.98.109`, porta customizada `10443`.
   - **Decisão: MSI offline.** O instalador online não tem modo silencioso documentado. O `FortiClient.msi` que ele baixa (7.2.13.1284, assinado pela Fortinet, SHA-256 `1CCAD597…57DB`) foi guardado em `installers\forticlient\` (projeto e pendrive, fora do Git) e é instalado com `/qn REBOOT=ReallySuppress`. O hash é conferido antes da instalação.
   - **Configuração:** o túnel **Laquila** é gravado no registro (`HKLM\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Laquila`) com os mesmos valores de uma máquina configurada manualmente: `Server = 201.48.98.109:10443` e `promptusername = 1` (o usuário digita login e senha ao conectar). **Nenhuma credencial é gravada.**
   - **Para atualizar a versão:** trocar o MSI em `installers\forticlient\` e o `path`/`sha256` do item `forticlient-vpn`.

---

## 2. Levantamento (2026-10-19, somente leitura, a partir de uma máquina do domínio)

| Item | Encontrado |
|---|---|
| Servidor "Marketing" | **`\\marketing`** (`marketing.laquila.local`, `192.168.0.55`), compartilhamento **`softwares`** |
| Office | `Office 2016\Instaladores\OfficeSetup.exe` (7 MB): instalador **online**, baixa o Office na hora. Ao lado: **`Office 2016\Office365-x64\ODT\`**, com `setup.exe` (Office Deployment Tool) e `installOfficeBusRet64.xml` (**Microsoft 365 Apps for business**, 64 bits, pt-br). Esse é o caminho que permite **instalação silenciosa**. |
| Antivírus | `Antivirus\F-Secure\` tem **dois** instaladores: `ElementsAgentInstaller[…-E03G-ATRT].exe` (o do procedimento) e `ElementsAgentInstaller[…-G70X-P3AB].exe`. **A chave da assinatura está no nome do arquivo** (por isso aqui aparece só o final dela). |
| Everest 30 | `\\fs01\Everest30\Instala_everest30.bat`: instalador completo em 10 passos. Extrai `EVEREST_30590.zip` (1,3 GB) para `C:\Exec_Laquila`, atualiza `C:\laquila`, cria o atalho em `C:\Users\Public\Desktop`, grava log em `C:\ProgramData\Laquila\EverestUpdate\`. **Exige administrador** e tem **muitos `pause`**, que esperam uma tecla. |
| Everest 2.11 / BDE | `BDE\everest1\` (executáveis do Everest 2.11), `BDE\DLLS\ntwdblib.dll`, `BDE\Client BDE **Install** v 5.1.1 Full\setup.exe` (os arquivos `setup-1.bin…` indicam instalador **Inno Setup**) e `BDE\Client BDE Update v 5.2\BDEInfoSetup.EXE` |
| Script antigo do BDE | `BDE\script\instalaeverest.bat`: da época do Windows XP/7. Copia de **`\\dbs08\EverestData`** (outro servidor) e coloca a `ntwdblib.dll` também em `System32`, o que é errado no Windows 64 bits para uma DLL de 32 bits. **Não será usado**: o procedimento atual (seção 1) é a referência. |

---

## 3. Pontos críticos

### 3.1 Acesso aos compartilhamentos

A máquina entra com a conta **local** `Laquila`, que **não é reconhecida** pelos servidores do domínio. Duas formas de dar acesso:

| # | Forma | Prós | Contras |
|---|---|---|---|
| **a** | **O técnico digita uma credencial do domínio** no início da etapa. Ela é usada só para conectar aos compartilhamentos (`net use`) durante a etapa, fica **apenas na memória** e é desconectada no final. | Não depende de mudança nos servidores; nenhuma senha é guardada | Exige o técnico presente na etapa (ele já está, por causa do domínio e da OU) |
| **b** | **Conta do próprio computador:** a etapa roda como **SYSTEM**, que acessa a rede como o computador (`305-1876$`). A infraestrutura dá permissão de **leitura** a "Computadores do domínio" nas pastas dos instaladores. | Nenhuma senha, nem digitada | Depende da infraestrutura; dá leitura a todos os computadores do domínio; a janela visível fica mais complexa |

### 3.2 Mudança de local (OU) no DC01

Mover o objeto do computador para a OU correta exige permissão no Active Directory, então fica **manual** por enquanto:

1. A janela mostra: "No DC01, mova o computador `305-1876` para a OU `<OU>` e pressione ENTER".
2. O script atualiza as políticas (`gpupdate /target:computer /force`) e **confere** a OU atual pelo registro: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Distinguished-Name`. Isso não exige credencial.
3. Se ainda não estiver na OU esperada, avisa e espera de novo.

### 3.3 Instalação silenciosa (sem cliques)

| Software | Forma silenciosa proposta | Situação |
|---|---|---|
| Office | ODT: `setup.exe /configure <xml>`, com `<Display Level="None" AcceptEULA="TRUE"/>` acrescentado a uma cópia do XML | ✅ Suportado pela Microsoft. Baixa o Office da internet (≈ 3 GB). A ativação é feita depois, no login do usuário com a conta Microsoft 365. |
| WithSecure | `ElementsAgentInstaller[…].exe` com o parâmetro silencioso do fabricante | ⚠️ **Confirmar o parâmetro** na documentação do WithSecure e testar em VM |
| Everest 30 | `cmd /c Instala_everest30.bat < NUL`: com a entrada redirecionada, os `pause` passam sozinhos | ⚠️ Testar em VM; o resultado é lido do log do próprio `.bat` |
| Everest 2.11 | Cópia de pasta e de DLL pelo PowerShell (`robocopy`) | ✅ Simples |
| BDE 5.1.1 Full | Inno Setup: `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` | ⚠️ Testar em VM |
| BDE Update 5.2 | `BDEInfoSetup.EXE`: tipo de instalador a identificar | ⚠️ Descobrir o parâmetro silencioso |

---

## 4. Onde se encaixa

```text
1. Login automático   2. Internet   3. Windows Update   4. Aplicativos (Chrome, 7-Zip, VLC)
5. Domínio (técnico ingressa; script detecta e reinicia)
6. Local no AD (OU)          ← NOVO: técnico move no DC01; script confere
7. Softwares corporativos    ← NOVO: scripts\Install-CorporateSoftware.ps1, lista em config\corporate-apps.json
     ├─ obtém acesso aos compartilhamentos (decisão C1)
     ├─ Office (ODT)
     ├─ Antivírus: técnico confirma a licença no portal → instala
     ├─ Everest 30 (.bat)
     └─ Everest 2.11: copia everest1 e ntwdblib.dll → BDE 5.1.1 Full → BDE Update 5.2
     resumo na tela: [OK] / [JÁ HAVIA] / [FALHA], como na etapa 4
```

Mesmo modelo da etapa de aplicativos:

- cada item é configurável no JSON;
- detecção de "já instalado" (idempotente);
- todos os itens são tentados;
- resumo na tela;
- log próprio (`Logs\corporate-software.log`).

**Novos tipos de ação**, além de `msi` e `exe`:

- `bat`, executado com a entrada redirecionada;
- `copy-folder`;
- `copy-file`.

---

## 5. Detecção de "já instalado" (proposta)

| Software | Detecção |
|---|---|
| Office | "Programas e Recursos" com nome `Microsoft 365*` |
| WithSecure | "Programas e Recursos" com nome `WithSecure*` ou `F-Secure*` (confirmar o nome exato) |
| Everest 30 | Pasta `C:\Exec_Laquila\EVEREST_30590` |
| Everest 2.11 | Pasta `C:\everest1` e arquivo `C:\Windows\SysWOW64\ntwdblib.dll` |
| BDE | "Programas e Recursos", ou registro do BDE (confirmar) |

---

## 6. Decisões

| # | Pergunta | Recomendação |
|---|---|---|
| **C1** | Acesso aos compartilhamentos | ✅ **Decidido (2026-10-19): credencial digitada na caixa do Windows**, só em memória, durante a etapa. |
| **C2** | Qual a **OU de destino** no DC01? | ✅ **Decidido:** `OU=Computadores novos,OU=LAQUILA,DC=laquila,DC=local`, com conferência automática (etapa 6 implementada). |
| **C3** | Office: qual produto e forma? | ✅ **Decidido (2026-10-19): ODT** (`config\office-odt.xml`). O técnico usa o **`OfficeSetup.exe`**. Avaliação (2026-10-19): ele é o instalador online do Click-to-Run (Microsoft Office 16.0.15831), que baixa e instala o produto da conta da empresa. Uma máquina instalada por ele (este computador) tem **`O365BusinessRetail`, x64, pt-br**: **exatamente o mesmo produto** do `installOfficeBusRet64.xml` do ODT. O `OfficeSetup.exe` não tem modo silencioso documentado e mostra janelas, inclusive a de conclusão. **Recomendação: ODT**, com resultado idêntico e silencioso (ver resposta na conversa de 2026-10-19). |
| **C4** | Antivírus: qual dos dois instaladores, e a verificação de licença | ✅ **Decidido (2026-10-19): `…E03G-ATRT`** ("WithSecure™ Network installer", OneClient 9.0.69). A verificação no portal fica **manual**: a janela pergunta "Há licença disponível no WithSecure? (S/N)". **A chave fica fora do Git**: o JSON guarda só o padrão do nome (`ElementsAgentInstaller*E03G*.exe`). O parâmetro silencioso ainda precisa ser confirmado. |
| **C5** | BDE: ordem de instalação | ✅ **Decidido: Update 5.2 primeiro, depois 5.1.1 Full**, conforme o procedimento. Observação: o "Update 5.2" (`BDEInfoSetup.EXE`) é o **"BDE Information Utility"**, instalador **Wise** (silencioso: `/s`), e não uma atualização do BDE. Por isso a ordem não causa conflito. O "5.1.1 Full" é o **Borland Database Engine**, instalador **Inno Setup** (silencioso: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`). |
| **C6** | BDE: é preciso configurar alias (`AliasCreator`, `Arquivo de configuração`)? | ✅ **Decidido (2026-10-19):** depois do BDE, copiar `\\marketing\softwares\BDE\Arquivo de configuração\IDAPI32.CFG` para `C:\Program Files (x86)\Borland\Common Files\BDE`; depois, criar os atalhos Everest e EverestLite na área de trabalho pública. |

---

## 7. Riscos

- **Parâmetros silenciosos não confirmados** (WithSecure, BDE 5.2, `.bat` do Everest 30): exigem teste em VM antes de produção.
- **Office:** download de cerca de 3 GB da Microsoft. Se o firewall inspecionar a CDN do Office, falha como o 7-Zip e o VLC; testar.
- **Chave do antivírus** no nome do arquivo: tratar como informação sensível (licença).
- **Duração:** Office + Everest 30 (zip de 1,3 GB) podem levar de 30 a 60 minutos.
- **Credencial (C1 = a):** se o técnico digitar uma conta sem acesso a alguma pasta, o item falha com mensagem clara e os demais seguem.
