# Login automático durante o provisionamento

Data: 2026-10-09

Status: **implementado**. Testado com as funções do Windows simuladas (seção 8). **O login automático real (LSA, registro e reboot) ainda precisa ser testado em VM.**

---

## 1. Objetivo

Fazer o Windows entrar sozinho na conta do técnico (`Laquila`) **depois de cada reboot** do provisionamento. Assim, a fase de Windows Update, que tem vários reboots, roda sem que o técnico precise fazer login a cada vez.

Esta funcionalidade substitui a antiga etapa fake "Primeiro logon" (`scripts\First-Logon.ps1`, removida).

---

## 2. Limitação técnica

Um script **não consegue fazer login sozinho**. Depois de um reboot, a máquina para na tela de login e nenhum script do projeto está rodando.

O que o script faz é **configurar o login automático do próprio Windows antes de cada reboot**. É o mesmo mecanismo que o bloco `<AutoLogon>` do `autounattend.xml` usa. No boot seguinte, o Windows entra sozinho na conta, **uma única vez**.

Pelo mesmo motivo, o **primeiro** login, logo após a instalação, não pode ser feito pelo script: antes dele, nenhum script do projeto está rodando. Esse primeiro login continua sendo feito pelo `<AutoLogon>` do XML.

---

## 3. Decisões (2026-10-09)

| # | Pergunta | Decisão |
|---|---|---|
| **L1** | Manter o `<AutoLogon>` do XML para o **primeiro** login? | ✅ **Manter.** Tirar só acrescentaria um passo manual, sem ganho real de segurança: a senha continua no XML, na criação da conta. |
| **L2** | Login automático **após cada reboot** do Windows Update? | ✅ **Sim.** Substitui a decisão D2 do Windows Update (técnico faz login após cada reboot). |
| **L3** | De onde vem a senha? | ✅ **Arquivo no pendrive** (`config\autologon.txt`). Ver os cuidados na seção 6. |
| **L4** | Bloquear a tela depois do login automático? | ✅ **Não.** A janela do provisionamento fica visível. |

---

## 4. Funcionamento

### 4.1 Arquivos

| Arquivo | Conteúdo |
|---|---|
| `scripts\AutoLogon.ps1` | Funções do login automático, carregadas pelo orquestrador |
| `scripts\Start-Provisioning.ps1` | Etapa 1 "Login automático" e chamadas antes de cada reboot e no final |
| `<pendrive>\config\autologon.txt` | Senha da conta em **Base64**. Fica **somente no pendrive** e está no `.gitignore`. |

### 4.2 Funções (`AutoLogon.ps1`)

| Função | O que faz |
|---|---|
| `Import-AutoLogonCredential` | Lê o `config\autologon.txt` e **confirma que a senha funciona** para a conta, sem abrir sessão. Depois guarda a senha como **segredo protegido do Windows (LSA)**. |
| `Test-AutoLogonCredential` | Indica se a senha já está guardada nesta máquina |
| `Enable-AutoLogon` | Configura o Windows para entrar sozinho na conta **no próximo boot, uma única vez** (`AutoLogonCount = 1`) |
| `Disable-AutoLogon` | Desliga o login automático. Com `-RemoveCredential`, apaga também a senha guardada. |
| `Remove-PlainTextAutoLogonPassword` | Remove a senha em **texto puro** que o Windows pode deixar no registro (`Winlogon\DefaultPassword`) |

### 4.3 Fluxo

```text
Primeiro login (automático, pelo <AutoLogon> do XML)
  └─ Start-Provisioning (pendrive)
       └─ Etapa 1 – Login automático
            ├─ remove senha em texto puro do registro, se existir
            ├─ senha já guardada?  sim → segue
            ├─ config\autologon.txt existe?  não → AVISO: login manual após os reboots
            └─ lê o arquivo → confere a senha → guarda no LSA
       ...
       └─ Windows Update pede reboot
            ├─ Enable-AutoLogon (vale para 1 boot)
            ├─ tela: "o Windows entra sozinho na conta Laquila"
            └─ reinicia → Windows entra sozinho → tarefa agendada reabre a janela
       ...
       └─ Fim
            ├─ concluído → Disable-AutoLogon -RemoveCredential (desliga e apaga a senha)
            └─ erro      → Disable-AutoLogon (desliga, mas mantém a senha para nova tentativa)
```

### 4.4 O que fica guardado na máquina

| Onde | O quê | Quando é removido |
|---|---|---|
| Segredo LSA `L$WorkstationProvisioning_AutoLogon` | Senha da conta, para os reboots | Ao concluir o provisionamento |
| Segredo LSA `DefaultPassword` | Cópia da senha lida pelo Windows no login automático | No fim e em caso de erro |
| Registro `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`: `AutoAdminLogon`, `DefaultUserName`, `DefaultDomainName`, `AutoLogonCount` | Configuração do login automático | `AutoAdminLogon` volta a `0` e `AutoLogonCount` é removido no fim e em caso de erro |

A senha **nunca** fica em texto puro no registro: se o Windows tiver deixado uma, ela é removida.

---

## 5. Formato do `config\autologon.txt`

Uma única linha com a senha codificada em **Base64 (UTF-8)**. Para gerar, rode num PowerShell, trocando `SENHA` pela senha temporária da conta:

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('SENHA')) |
    Set-Content -LiteralPath 'E:\config\autologon.txt' -NoNewline
```

Troque `E:` pela letra do pendrive.

- **Crie o arquivo direto no pendrive**, nunca na pasta do projeto: ela é sincronizada no OneDrive e versionada no Git.
- **A senha precisa ser a mesma** da conta criada pelo `autounattend.xml`. Se for diferente, a etapa 1 avisa e o login após os reboots passa a ser manual.

---

## 6. Segurança e consequências

| # | Ponto | Situação |
|---|---|---|
| 1 | **A senha fica em um arquivo no pendrive (L3).** O CLAUDE.md pede para considerar que o pendrive pode ser acessado por terceiros. | Risco **igual ao atual**, porque a mesma senha temporária já está no `autounattend.xml` do pendrive. Base64 **não** é criptografia: só evita a leitura de relance. A senha é temporária e deve ser trocada ao final (item 1 do relatório de erros). |
| 2 | Senha guardada na máquina durante o provisionamento | Guardada como segredo protegido (LSA), não em texto puro. Um administrador com ferramentas específicas consegue lê-la. É apagada ao concluir. |
| 3 | **Login automático esquecido ligado na máquina entregue** | Cada ativação vale para **1 boot** (`AutoLogonCount = 1`), e o login automático é desligado no fim e em caso de erro. A validação final (Fase 8) deve conferir `AutoAdminLogon = 0`. |
| 4 | Sessão de administrador aberta e desbloqueada durante as atualizações (L4) | Aceito: o provisionamento acontece em ambiente controlado. |
| 5 | Provisionamento interrompido por erro | O login automático é desligado, mas a senha guardada é mantida. Para tentar de novo, basta logoff e login. Se a máquina for abandonada nesse estado, a senha fica no LSA até a limpeza final (Fase 9). |
| 6 | Arquivo ausente, inválido ou com senha errada | O provisionamento **não para**: a etapa 1 registra o aviso e o técnico faz login manualmente após cada reboot, que era o comportamento anterior (D2). |
| 7 | Windows 11 pode bloquear o login automático em algumas configurações de "entrar sem senha" | Baixo risco para conta local. Conferir na VM. |

---

## 7. Verificação manual

Num PowerShell **como administrador** na máquina provisionada:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
    Select-Object AutoAdminLogon, AutoLogonCount, DefaultUserName, DefaultPassword
```

| Momento | Esperado |
|---|---|
| Durante a contagem para um reboot | `AutoAdminLogon = 1`, `AutoLogonCount = 1`, `DefaultUserName = Laquila`, **`DefaultPassword` vazio** |
| Após o provisionamento concluído | `AutoAdminLogon = 0`, sem `AutoLogonCount`, **`DefaultPassword` vazio** |

---

## 8. Testes realizados (2026-10-09, Windows PowerShell 5.1)

| Teste | Resultado |
|---|---|
| Compilação das funções do Windows (LSA e validação de senha) | ✅ |
| Leitura do `autologon.txt`: válido / Base64 inválido / vazio | ✅ Senha lida corretamente / mensagens de erro claras nos dois casos de falha |
| Orquestrador com arquivo de senha: reboot e retomada | ✅ Senha importada na 1ª execução, login automático ativado antes do reboot e mensagem "o Windows entra sozinho". Na retomada: "senha guardada". No fim: desligado e senha apagada. |
| Orquestrador sem arquivo de senha | ✅ Aviso no log; tela orienta login manual |
| Erro na etapa de Windows Update | ✅ Login automático desligado, senha mantida para nova tentativa |

Nos testes do orquestrador, as funções que gravam no LSA e no registro foram simuladas, para não ativar o login automático na máquina de desenvolvimento.

**Ainda não testado (fazer em VM com snapshot):**

- gravação real no LSA;
- validação real da senha;
- login automático real após o reboot;
- remoção da senha em texto puro deixada pelo XML.
