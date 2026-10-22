# Planejamento: ingresso no domínio laquila.local

Data: 2026-10-19

Status: **fase 1 implementada (2026-10-19): ingresso MANUAL pelo técnico, verificado pelo provisionamento.** O ingresso automático (seções 3 a 6) fica para depois, aguardando as decisões J1 a J4.

## Fase 1 (implementada): o técnico ingressa, o provisionamento confere

Decisão de 2026-10-19:

- por enquanto, o ingresso no domínio **não é automático**;
- a etapa fica **depois dos aplicativos**.

```text
1. Login automático   2. Internet   3. Windows Update   4. Aplicativos
5. Domínio  ← Confirm-DomainMembership (Start-Provisioning.ps1), domínio em config\domain.json
     ├─ está no domínio esperado?  sim → etapa concluída → provisionamento concluído
     └─ não → mostra na tela "PARA CONTINUAR O PROVISIONAMENTO, É NECESSÁRIO INGRESSAR NO DOMÍNIO",
              com as instruções (sysdm.cpl → Alterar → Domínio → credencial → reiniciar),
              e PAUSA o provisionamento, sem erro
              → depois do reinício, a tarefa agendada reabre a janela e a etapa confere de novo
              → enquanto não estiver no domínio, avisa de novo
```

Como funciona:

- **Verificação:** `Win32_ComputerSystem.PartOfDomain` e `.Domain` comparado com `config\domain.json` (`"domain": "laquila.local"`, sem nenhuma senha).
- **Domínio diferente:** se a máquina estiver em outro domínio, a etapa avisa e continua pausada.
- **O que fica ativo durante a pausa:** a tarefa agendada, o login automático, o bloqueio de reinício do Windows Update e o plano de energia. Assim, o reinício feito pelo técnico depois do ingresso volta sozinho para o provisionamento.
- **Nome do computador (2026-10-19):** o técnico **define o novo nome ao ingressar** (padrão `###-####`, ex.: `305-1876`, `102-1787`, `101-2212`).
  - Problema: o login automático da conta local `Laquila` usa o nome do computador (`DefaultDomainName`). Com o nome antigo, ele falharia depois do reinício.
  - Solução: a etapa **acompanha o ingresso enquanto o técnico o faz**, verificando a cada 2 s:
    - `HKLM\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain` indica ingresso pendente;
    - `ComputerName\ComputerName` traz o novo nome, que só vale depois do reinício.
  - Ao detectar, o script **reconfigura o login automático com o novo nome** (`Enable-AutoLogon -ComputerName`) e **reinicia sozinho**, com contagem de 60 s.
  - As instruções pedem ao técnico para clicar em **"Reiniciar Mais Tarde"** na janela do Windows. Se ele reiniciar pelo Windows antes, o login automático pode falhar, e a tela orienta o login em `.\Laquila`.
- **Padrão do nome:** `computerNamePattern` (`^\d{3}-\d{4}$`) e `computerNameExample` (`305-1876`) em `config\domain.json`. Um nome fora do padrão **só gera aviso** (`[WARN]`), porque o nome é definido manualmente.

**Testado em 2026-10-19:**

- orquestrador com a etapa simulada: fora do domínio → instruções na tela, pausa sem erro, estado "em andamento"; depois do "reinício", no domínio → etapa concluída e provisionamento concluído, com tudo restaurado;
- **com novo nome:** ingresso detectado durante a espera (novo nome `305-1876`) → login automático reconfigurado com `305-1876` → reinício → depois do reinício, no domínio como `305-1876` → concluído;
- nome fora do padrão (`DESKTOP-NOVO`) → aviso no log, sem bloquear;
- leituras reais neste computador: `laquila.local` / `102-1772`, sem ingresso pendente.

**Falta testar em VM:** o ingresso real pelo `sysdm.cpl`, a detecção pelo `Netlogon\JoinDomain` e o login automático com o novo nome depois do reinício.

**Primeiro teste em máquina (2026-10-19): o login automático NÃO aconteceu depois do reinício do ingresso.**

- **Causa provável:** o próprio ingresso grava `Winlogon\DefaultDomainName` = domínio (para a tela de login sugerir o domínio). Se isso acontecer **depois** do ajuste feito pelo script, o Windows tenta entrar como `LAQUILA\Laquila`, que não existe no domínio.
- **Correção:**
  - durante os 60 s da contagem, a etapa confere o login automático a cada segundo (`Repair-DomainJoinAutoLogon`). Se o Windows tiver alterado o valor, reconfigura e registra `[WARN] O Windows alterou o login automático (...)`;
  - a mesma conferência é feita logo antes do reinício;
  - a cada execução, o log registra como o login automático estava ao iniciar (`Login automático encontrado ao iniciar: ...`). Um `AutoLogonCount` menor que 10 indica que o último login foi automático.
- **Para confirmar a causa:** rodar `tools\Get-ProvisioningDiagnostic.ps1` como Administrador na máquina testada. O evento 4625 mostra com que conta o Windows tentou entrar. Por exemplo, `LAQUILA\Laquila` com `0xc0000064` confirma a causa acima. Outra possibilidade a descartar: o aviso legal da GPO (seção 2).

---

Corresponde à **Fase 4** do roadmap do CLAUDE.md (seção 10).

---

## 1. Objetivo

Colocar a máquina no domínio **`laquila.local`** durante o provisionamento:

- com o nome de computador no padrão da empresa;
- na OU correta;
- **sem nenhuma senha de domínio** no pendrive, no Git, em arquivo ou em log (CLAUDE.md, seção 11);
- validando o resultado depois do reboot.

---

## 2. O que o domínio revela (levantamento de 2026-10-19)

Feito a partir de um computador já no domínio (`102-1772`), somente com leituras:

| Item | Resultado | Impacto |
|---|---|---|
| Controladores de domínio | `DC01.laquila.local` e `DC02.laquila.local` (`192.168.0.120`), site `Matriz`, encontrados pelo DNS (`_ldap._tcp.dc._msdcs.laquila.local`) | A verificação pode usar `nltest /dsgetdc:laquila.local` |
| Política de execução de scripts por GPO | `MachinePolicy` e `UserPolicy` **não definidas** | ✅ Os scripts continuam rodando com `-ExecutionPolicy Bypass` depois do ingresso |
| LAPS | Não configurado | ✅ A senha da conta `Laquila` não é trocada pelo domínio; o login automático continua funcionando |
| WSUS | Não configurado | ✅ O Windows Update não muda depois do ingresso |
| Certificado raiz do Fortinet por GPO | **Não** distribuído | ⚠️ O ingresso **não** resolve a inspeção SSL do 7-Zip e do VLC (`docs\planejamento-aplicativos.md`, seção 5) |
| Horário | Diferença de 0,02 s com o DC | ✅ Kerberos exige menos de 5 min |
| Aviso legal no login (`legalnoticetext`) | Texto com **um espaço**, título vazio | 🟡 Provavelmente não aparece. Se aparecer, **impede o login automático**: conferir numa VM depois do ingresso. |
| Padrão de nome | Este computador se chama `102-1772` | ❓ Regra a confirmar (decisão J3) |

**A confirmar com a infraestrutura** (exige acesso de administrador ao domínio): a lista de GPOs aplicadas às estações (`gpresult /scope computer /r` como administrador) e se alguma delas desativa o login automático, exige `Ctrl+Alt+Del` ou restringe o login de contas locais.

---

## 3. Onde se encaixa

Seguindo a ordem do CLAUDE.md (seção 8): Windows Update → **Domain Join → reboot** → aplicativos.

```text
1. Login automático
2. Verificação de internet
3. Windows Update (ciclos e reboots)
4. Domínio  ← NOVO: scripts\Join-Domain.ps1, configuração em config\domain.json
     ├─ já está em laquila.local? → pula
     ├─ verifica rede corporativa (DNS e controlador de domínio) → aguarda, como na etapa 2
     ├─ obtém a credencial (decisão J1)
     ├─ renomeia + ingressa em um único passo (Add-Computer -NewName, um único reboot)
     └─ reinicia → após o login, valida o ingresso
5. Aplicativos
```

---

## 4. Funcionamento proposto

### 4.1 Configuração: `config\domain.json` (sem nenhuma senha)

```json
{
    "domain": "laquila.local",
    "ouPath": "OU=Estacoes,DC=laquila,DC=local",
    "computerName": { "mode": "prompt" }
}
```

O `ouPath` e o `computerName` dependem das decisões J3 e J4.

### 4.2 Antes de ingressar (pré-requisitos)

| Verificação | Se falhar |
|---|---|
| A máquina já está em `laquila.local` | Pula a etapa (idempotente) |
| O DNS resolve os controladores (`_ldap._tcp.dc._msdcs.laquila.local`) | **Aguarda**, com instruções na tela: "conecte o cabo da **rede corporativa**". A rede de visitantes ou só de internet não alcança o domínio. |
| Um controlador responde (`nltest /dsgetdc:laquila.local`) | Aguarda, como acima |
| Diferença de horário com o DC menor que 5 min | Sincroniza com `w32tm /resync`; se não conseguir, gera erro |
| O nome do computador é válido: até 15 caracteres, sem caracteres inválidos | Pede de novo ou gera erro |

### 4.3 Ingresso

- **Um único reboot:** `Add-Computer -DomainName laquila.local -NewName <nome> -OUPath <OU> -Credential <credencial> -Options JoinWithNewName`.
- **Erros tratados**, com mensagem clara e nova tentativa quando fizer sentido:
  - senha errada (até 3 tentativas);
  - conta sem permissão;
  - nome já existente no AD;
  - OU inexistente.
- **Login automático depois do reboot:** a conta `Laquila` é **local**. Antes do reboot, o login automático é configurado com `DefaultDomainName` = **novo nome do computador**. Sem isso, o Windows tentaria entrar com o nome antigo, ou no domínio, e falharia.
- **Credencial:** usada só nessa chamada e descartada em seguida. **Nunca** aparece no log.

### 4.4 Depois do reboot (validação)

| Verificação | Comando |
|---|---|
| A máquina está no domínio certo | `(Get-CimInstance Win32_ComputerSystem).PartOfDomain` e `.Domain -eq 'laquila.local'` |
| O nome é o esperado | `$env:COMPUTERNAME` |
| O canal seguro com o domínio funciona | `Test-ComputerSecureChannel` |

Se a validação falhar, a etapa termina com erro e o provisionamento é interrompido.

---

## 5. Credencial: alternativas

| # | Alternativa | Como funciona | Prós | Contras |
|---|---|---|---|---|
| **a** | **Pedir ao técnico na hora** | Quando chega a etapa 4, abre a janela padrão do Windows pedindo usuário e senha | Mais seguro: a senha só existe na memória, por segundos | O técnico precisa estar presente **depois** do Windows Update, que pode levar horas |
| **b** | **Pedir no início e guardar protegida até o ingresso** | Na etapa 1, o técnico digita a credencial. Ela é guardada **criptografada pelo Windows (DPAPI)**, só utilizável pela conta `Laquila` nesta máquina, e **apagada logo após o ingresso** ou em caso de erro. | O técnico só interage no início; o restante segue sozinho, inclusive os reboots | A credencial fica no disco, criptografada, durante o Windows Update. Um administrador local da máquina consegue decifrá-la nesse período. |
| **c** | **Ingresso offline (`djoin`)** | Um administrador do domínio pré-cadastra cada computador no AD e gera um arquivo de ingresso; o arquivo vai no pendrive | Nenhuma senha é digitada nem guardada | Precisa saber o nome de cada máquina antes; o arquivo é sensível e de uso único; dá trabalho para muitas máquinas |

**Em qualquer alternativa: usar uma conta dedicada ao ingresso**, com permissão **apenas** para criar e ingressar computadores na OU de estações (delegação no AD), e **não** um administrador do domínio. Se essa conta vazar, o dano fica limitado.

---

## 6. Decisões

| # | Pergunta | Recomendação |
|---|---|---|
| **J1** | Como obter a credencial | **(b) Pedir no início, guardada com DPAPI e apagada logo após o ingresso.** Mantém o provisionamento automático depois da etapa 1, como o login automático. Se a política da empresa não aceitar a credencial no disco, **(a)**. |
| **J2** | Qual conta usar | **Conta dedicada ao ingresso**, com permissão só na OU de estações. Criação pela infraestrutura. |
| **J3** | Regra do nome do computador | O `102-1772` parece um número de patrimônio. **Se for patrimônio:** o técnico digita na etapa 1 (validado: até 15 caracteres). **Se houver regra automática** (ex.: prefixo + número de série da BIOS): calcular sozinho. |
| **J4** | OU de destino | Caminho exato da OU das estações (ex.: `OU=Estacoes,DC=laquila,DC=local`), informado pela infraestrutura |
| **J5** | Ordem das etapas | **Domínio antes dos aplicativos** (CLAUDE.md). Como o certificado do Fortinet não vem por GPO, a ordem não muda o problema dos downloads. |

---

## 7. Riscos

- **GPOs aplicadas depois do ingresso:** podem mudar o comportamento da máquina no meio do provisionamento. Exemplos: aviso legal, `Ctrl+Alt+Del` obrigatório, bloqueio de login de conta local, desativação do login automático. As principais foram verificadas e estão OK (seção 2), mas a lista completa de GPOs precisa ser confirmada.
- **Rede corporativa obrigatória:** o ingresso só funciona com acesso aos controladores. Wi-Fi corporativo com autenticação 802.1X pode exigir a máquina já no domínio: **usar cabo**.
- **Nome já existente no AD** (máquina reformatada com o mesmo nome): o ingresso falha, a não ser que a conta dê permissão para reutilizar o objeto. Definir com a infraestrutura.
- **Credencial (J1 = b):** fica criptografada no disco durante o Windows Update. É apagada após o ingresso e em caso de erro; falta prever a limpeza se a máquina for abandonada (Fase 9).

---

## 8. Testes previstos

- **Unidade (Pester):** com `Add-Computer`, DNS, `nltest`, `w32tm` e DPAPI simulados:
  - já no domínio → pula;
  - sem rede corporativa → aguarda;
  - nome inválido;
  - senha errada (novas tentativas);
  - nome já existente;
  - sucesso com um único reboot e `DefaultDomainName` = novo nome;
  - validação depois do reboot;
  - a credencial nunca aparece no log.
- **VM no domínio:**
  - ingresso real com a conta dedicada;
  - login automático depois do reboot;
  - verificação do aviso legal e das GPOs.
