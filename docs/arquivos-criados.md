# Arquivos criados na máquina pelo provisionamento

Última atualização: 2026-10-08

Lista dos arquivos que a automação cria na máquina provisionada, com o motivo de cada um e se ele é removido.

Considera:

- o `autounattend.xml` oficial (`Arquivos de autounattend\Sem interação com partição de disco\GPT\Custom diskpart\No Assertions about the disk\`);
- os scripts atuais de `scripts\`.

Atualize este documento sempre que um script passar a criar, mover ou apagar arquivos.

## Pastas principais

| Pasta | Conteúdo |
|---|---|
| `C:\Windows\Setup\Scripts\` | Scripts extraídos do `autounattend.xml` durante a instalação do Windows, e os logs deles |
| `C:\ProgramData\WorkstationProvisioning\` | Estado do provisionamento, cópia local dos scripts do projeto e logs |

Os scripts do pendrive (`<unidade>:\scripts\`) são copiados para **`C:\ProgramData\WorkstationProvisioning\scripts\`** na primeira execução do `Start-Provisioning.ps1`. A tarefa agendada sempre executa essa cópia local, então o provisionamento continua mesmo se o pendrive for retirado depois do primeiro reboot.

## Arquivos

| Nome | Caminho | Motivo da criação | Removido? |
|---|---|---|---|
| `unattend.xml` | `C:\Windows\Panther\` | Cópia do XML do pendrive feita pelo `pe.cmd` (WinPE). O Windows lê as etapas seguintes da instalação a partir dela. | Sim, no primeiro logon (`First-Logon.ps1` embutido) |
| `Specialize.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Roda durante a instalação: desliga a exigência de conta Microsoft (`BypassNRO`), chama o `RemovePackages.ps1` e define senhas sem expiração. | Não |
| `RemovePackages.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Remove os apps Xbox. | Não |
| `DefaultUser.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Desliga a gravação de jogos (Game DVR) no perfil padrão de novos usuários. | Não |
| `First-Logon.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Roda no primeiro logon: zera o login automático, apaga o `unattend.xml` e abre o `Start-Provisioning.ps1` do pendrive. | Não |
| `Specialize.log`, `RemovePackages.log`, `DefaultUser.log`, `First-Logon.log` | `C:\Windows\Setup\Scripts\` | Log de cada script acima | Não |
| `Start-Provisioning.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local do orquestrador. É ela que a tarefa agendada executa após cada reboot. | Não |
| `AutoLogon.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local das funções de login automático (etapa 1) | Não |
| `Test-InternetConnection.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local da verificação de internet (etapa 2) | Não |
| `Install-WindowsUpdates.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local da etapa de Windows Update (etapa 3) | Não |
| `Install-Programs.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Copiado só porque está na pasta `scripts\` do pendrive: a cópia leva **tudo** o que houver nela. Ainda não é usado. | Não |
| `state.json` | `C:\ProgramData\WorkstationProvisioning\` | Progresso do provisionamento: etapas concluídas, ciclo do Windows Update e status. Permite retomar após reboot. | Não. Fica com `Status: Completed` |
| `state.json.tmp` | `C:\ProgramData\WorkstationProvisioning\` | Arquivo temporário da gravação segura do `state.json` | Sim, logo em seguida (é renomeado para `state.json`) |
| `windows-update-failures.json` | `C:\ProgramData\WorkstationProvisioning\` | Quantas vezes cada atualização falhou. Uma atualização que falha 2 vezes deixa de ser tentada. Só é criado se o Windows Update chegar a instalar algo. | Não |
| `deployment.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Log principal: etapas, rede, ciclos, reboots e erros | Não |
| `windows-update.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Detalhe do Windows Update: atualizações encontradas e ignoradas, e resultado de cada uma | Não |
| `Resume` | `C:\Windows\System32\Tasks\WorkstationProvisioning\` | Definição da tarefa agendada `\WorkstationProvisioning\Resume`, que reabre o provisionamento a cada login | Sim, quando o provisionamento termina |

## Outras alterações no sistema (não são arquivos)

| Item | Onde | Motivo | Removido? |
|---|---|---|---|
| Segredo `L$WorkstationProvisioning_AutoLogon` | LSA (segredos protegidos do Windows) | Senha da conta, lida uma vez do `config\autologon.txt` do pendrive, para o login automático após os reboots | Sim, ao concluir o provisionamento. Em caso de erro é mantido para uma nova tentativa. |
| Segredo `DefaultPassword` | LSA | Cópia da senha lida pelo Windows no login automático do próximo boot | Sim, no fim e em caso de erro |
| `AutoAdminLogon`, `DefaultUserName`, `DefaultDomainName`, `AutoLogonCount` | Registro: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` | Configuração do login automático, válida para 1 boot | `AutoAdminLogon` volta a `0` e `AutoLogonCount` é removido no fim e em caso de erro |

O arquivo `config\autologon.txt` fica **somente no pendrive**: não é copiado para a máquina. Detalhes em `docs\planejamento-login-automatico.md`.

## Arquivos temporários da instalação (WinPE)

| Nome | Caminho | Motivo da criação |
|---|---|---|
| `pe.cmd` | `X:\` | Script gerado pelo XML que particiona o disco, aplica a imagem do Windows e copia o `unattend.xml` |
| `diskpart.txt` | `X:\` | Comandos do `diskpart` (`SELECT DISK=0`, `CLEAN`, partições GPT) |

`X:` é o disco temporário em memória do instalador do Windows. Esses arquivos somem sozinhos no primeiro reboot e não ficam na máquina.

## Limpeza final (pendente)

Hoje nada disso é apagado ao final, exceto o `unattend.xml` e a tarefa agendada. A limpeza é a Fase 9 do roadmap do CLAUDE.md, que deve:

- apagar os scripts de `C:\Windows\Setup\Scripts\` e a cópia em `C:\ProgramData\WorkstationProvisioning\scripts\`;
- mover os logs de `C:\Windows\Setup\Scripts\` para `C:\ProgramData\WorkstationProvisioning\Logs\`;
- manter o `state.json` e os logs para auditoria e troubleshooting.

## Como reexecutar o provisionamento do zero

Em uma máquina de teste, apague `C:\ProgramData\WorkstationProvisioning\state.json` e execute o `Start-Provisioning.ps1` novamente.
