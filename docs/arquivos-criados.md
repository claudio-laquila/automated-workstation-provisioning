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

Os scripts do pendrive (`<unidade>:\scripts\`) são copiados para **`C:\ProgramData\WorkstationProvisioning\scripts\`** na primeira execução do `Start-Provisioning.ps1`. A tarefa agendada sempre executa essa cópia local, então o provisionamento continua sem o pendrive.

**Quando retirar o pendrive:** a janela avisa em verde **"O PENDRIVE (…) JÁ PODE SER RETIRADO"**, logo depois da etapa 1 (login automático) da primeira execução, e registra o aviso no `deployment.log`. Nesse momento, os scripts, os arquivos de config e a pasta `installers\` já foram copiados, e a senha do login automático já está guardada no Windows. Retirar cedo também evita que um reinício abra o menu do pendrive (Ventoy) em vez do Windows, quando o pendrive está em primeiro lugar na ordem de boot. O pendrive volta a ser necessário só para rodar o diagnóstico (`tools\`) ou para recomeçar o provisionamento do zero.

## Arquivos

| Nome | Caminho | Motivo da criação | Removido? |
|---|---|---|---|
| `unattend.xml` | `C:\Windows\Panther\` | Cópia do XML do pendrive feita pelo `pe.cmd` (WinPE). O Windows lê as etapas seguintes da instalação a partir dela. | Sim, no primeiro logon (`First-Logon.ps1` embutido) |
| `Specialize.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Roda durante a instalação: desliga a exigência de conta Microsoft (`BypassNRO`), chama o `RemovePackages.ps1` e define senhas sem expiração. | Não |
| `RemovePackages.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Remove os apps Xbox e o Microsoft Solitaire Collection. | Não |
| `DefaultUser.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Desliga a gravação de jogos (Game DVR) no perfil padrão de novos usuários. | Não |
| `First-Logon.ps1` | `C:\Windows\Setup\Scripts\` | Extraído do XML. Roda no primeiro logon: zera o login automático, apaga o `unattend.xml` e abre o `Start-Provisioning.ps1` do pendrive. | Não |
| `Specialize.log`, `RemovePackages.log`, `DefaultUser.log`, `First-Logon.log` | `C:\Windows\Setup\Scripts\` | Log de cada script acima | Não |
| `Start-Provisioning.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local do orquestrador. É ela que a tarefa agendada executa após cada reboot. | Não |
| `AutoLogon.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local das funções de login automático (etapa 1) | Não |
| `AutoRestartPolicy.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local das funções que bloqueiam e restauram o reinício automático do Windows Update | Não |
| `auto-restart-policy-backup.json` | `C:\ProgramData\WorkstationProvisioning\` | Configuração original do reinício automático do Windows Update, guardada antes de alterá-la | Sim, ao concluir (depois de restaurar a configuração) |
| `PowerPolicy.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local das funções que desativam e restauram a hibernação e a suspensão | Não |
| `power-policy-backup.json` | `C:\ProgramData\WorkstationProvisioning\` | Configuração original de hibernação e suspensão, guardada antes de alterá-la | Sim, ao concluir (depois de restaurar a configuração) |
| `Test-InternetConnection.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local da verificação de internet (etapa 2) | Não |
| `Install-WindowsUpdates.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local da etapa de Windows Update (etapa 3) | Não |
| `Install-Applications.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local da etapa de aplicativos (etapa 4) | Não |
| `domain.json` | `C:\ProgramData\WorkstationProvisioning\config\` | Cópia da configuração do domínio esperado (`laquila.local`), do padrão do nome do computador (`###-####`) e da OU de destino (`Computadores novos`), sem senha. Usada pelas etapas 5 e 6. | Não |
| `apps.json` | `C:\ProgramData\WorkstationProvisioning\config\` | Cópia da lista de aplicativos do pendrive. O `autologon.txt` **não** é copiado. | Não |
| `Install-CorporateSoftware.ps1` | `C:\ProgramData\WorkstationProvisioning\scripts\` | Cópia local da etapa de softwares corporativos (etapa 7) | Não |
| `corporate-apps.json`, `office-odt.xml` | `C:\ProgramData\WorkstationProvisioning\config\` | Lista dos softwares corporativos e configuração do Office (ODT). Sem senha e sem a chave do antivírus (só o padrão do nome). | Não |
| `setup.exe`, `configuration.xml` | `C:\ProgramData\WorkstationProvisioning\Temp\odt\` | Cópia do ODT e da configuração do Office, executada fora da pasta do servidor (que tem um Office antigo) | Não (limpeza final, Fase 9) |
| `empty-input.txt` | `C:\ProgramData\WorkstationProvisioning\Temp\` | Arquivo vazio usado como entrada do `.bat` do Everest 3.0, para os `pause` passarem sozinhos | Não (limpeza final, Fase 9) |
| `corporate-software.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Detalhe da etapa 7: conexão aos compartilhamentos (sem senha), cada item e resumo | Não |
| `everest30.log`, `everest30.log.err` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Saída do `Instala_everest30.bat` | Não |
| Office, WithSecure, BDE (Update 5.2 e 5.1.1) | Pastas de programas | Instalados pela etapa 7 | Não (são os softwares da máquina) |
| `C:\Exec_Laquila\EVEREST_30590\` | `C:\Exec_Laquila\` | Everest 3.0, criado pelo `.bat` do servidor | Não |
| `C:\everest1\` | `C:\` | Arquivos do Everest 2.11, copiados de `\\marketing\softwares\BDE\everest1` | Não |
| `ntwdblib.dll` | `C:\Windows\SysWOW64\` | DLL usada pelo Everest 2.11/BDE | Não |
| BDE (Borland Database Engine) | `C:\Program Files (x86)\Borland\Common Files\BDE\` (mesma pasta das máquinas instaladas manualmente; digitada pela etapa na janela do instalador) | Instalado pelo BDE 5.1.1 Full | Não |
| Microsoft ODBC Driver 11 for SQL Server | Pastas de programas | Instalado pela etapa 7 (`\\fs01\Everest30\msodbcsql-client-11.msi`) | Não |
| `msi-odbc11.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Log detalhado do `msiexec` do ODBC Driver 11 | Não |
| FortiClient VPN 7.2.13 | `C:\Program Files\Fortinet\FortiClient\` | Instalado pela etapa 7 a partir de `installers\forticlient\FortiClientVPN-7.2.13.1284.msi` (cerca de 145 MB, copiado do pendrive) | Não |
| `msi-forticlient-vpn.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Log detalhado do `msiexec` do FortiClient VPN | Não |
| `IDAPI32.CFG` | Pasta registrada pelo BDE em `HKLM\SOFTWARE\WOW6432Node\Borland\Database Engine\CONFIGFILE01` | Configuração do BDE (aliases), copiada do servidor e substituída a cada execução | Não |
| `Everest.lnk`, `EverestLite.lnk` | `C:\Users\Public\Desktop\` | Atalhos para `C:\everest1\MEU.exe` e `C:\everest1\MeuLite.exe`, para todos os usuários | Não |
| `installers\<id>\<arquivo>` | `C:\ProgramData\WorkstationProvisioning\installers\` | Cópia dos instaladores de reserva do pendrive, usados se o download falhar (cerca de 200 MB) | Não (limpeza final, Fase 9) |
| `<arquivo>.msi` | `C:\ProgramData\WorkstationProvisioning\Downloads\` | Instalador baixado do site oficial | Sim, logo após a instalação |
| `applications.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Detalhe da etapa de aplicativos: download, validação, instalação e resumo | Não |
| `msi-<id>.log` | `C:\ProgramData\WorkstationProvisioning\Logs\` | Log detalhado do `msiexec` de cada aplicativo (`/l*v`) | Não |
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
| `AutoAdminLogon`, `DefaultUserName`, `DefaultDomainName`, `AutoLogonCount` | Registro: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` | Configuração do login automático, ativada a cada execução para até 10 logins | `AutoAdminLogon` volta a `0` e `AutoLogonCount` é removido no fim e em caso de erro |
| Hibernação desligada; tempos para **suspender**, **hibernar** e **desligar a tela** = nunca (tomada e bateria) | Plano de energia ativo (`powercfg`) | Impede a máquina de hibernar, suspender ou apagar a tela durante o provisionamento, inclusive na tela de login depois de um reboot | Sim, **restaurados ao concluir** (valores originais). Em caso de erro são mantidos. Reverter manualmente: `powercfg /hibernate on` e os tempos desejados (`powercfg /change standby-timeout-ac <min>`, `monitor-timeout-ac <min>` etc.). Fechar a tampa **não** é alterado. |
| Túnel de VPN **Laquila** (`Server = 201.48.98.109:10443`, pede usuário ao conectar) | Registro: `HKLM\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Laquila` | Configuração da VPN, igual à das máquinas configuradas manualmente. Sem credenciais. | Não |
| Conexões aos compartilhamentos `\\marketing\softwares` e `\\fs01\Everest30` | Sessão do Windows (`New-SmbMapping`, não persistente) | Acesso aos instaladores com a credencial do domínio digitada na caixa do Windows (só em memória) | Sim, no fim da etapa 7, mesmo em caso de erro |
| `NoAutoRebootWithLoggedOnUsers = 1` | Registro: `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` | Impede o Windows Update de reiniciar sozinho durante o provisionamento | Sim, **restaurado ao concluir** (valor original). Em caso de erro é mantido. Reverter manualmente: `Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoRebootWithLoggedOnUsers` |

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
