# Windows Workstation Provisioning

## 1. Objetivo do projeto

Este projeto tem como objetivo automatizar o processo de formatação, instalação e configuração inicial de computadores Windows 11 Pro utilizados no ambiente corporativo.

A ideia é transformar um computador recém-formatado em uma workstation pronta para uso com o mínimo possível de intervenção manual.

O fluxo desejado é:

1. Inicializar o computador através de pendrive/ISO de instalação do Windows.
2. Executar instalação totalmente unattended.
3. Limpar completamente o disco interno correto.
4. Recriar o particionamento utilizando GPT/UEFI.
5. Instalar o Windows 11 Pro.
6. Executar configurações pós-instalação.
7. Executar Windows Update.
8. Instalar todas as atualizações disponíveis.
9. Adicionar o computador ao domínio corporativo.
10. Instalar softwares corporativos e ferramentas padrão.
11. Executar configurações adicionais de segurança/padronização.
12. Registrar logs de todas as etapas.
13. Remover informações e arquivos sensíveis utilizados durante o provisionamento.
14. Finalizar deixando a máquina pronta para entrega ao usuário.

O projeto deve ser desenvolvido pensando em reutilização, manutenção e execução em múltiplos computadores.

---

# 2. Ambiente

Sistema operacional alvo:

* Windows 11 Pro
* Arquitetura: x64/amd64
* Firmware: UEFI
* Particionamento: GPT

O meio de instalação normalmente será um pendrive contendo o Windows e os arquivos de automação.

Exemplo:

```text
USB/
├── autounattend.xml
├── scripts/
├── installers/
├── config/
└── logs/
```

---

# 3. Instalação unattended

O arquivo principal da instalação é:

```text
autounattend.xml
```

Ele é responsável principalmente por:

* idioma
* teclado
* região
* edição do Windows
* instalação unattended
* particionamento
* criação/configuração inicial
* OOBE
* execução dos scripts necessários

O XML deve ser utilizado principalmente como orquestrador.

Lógica complexa deve ficar em PowerShell e não dentro do XML.

---

# 4. Particionamento

O disco alvo atualmente é:

```text
Disk 0
```

O pendrive aparece normalmente como:

```text
Disk 1 - ESD-USB
```

É obrigatório evitar qualquer operação no pendrive.

O objetivo é apagar completamente o Disk 0.

O computador pode chegar com:

* partições OEM
* múltiplas partições Recovery
* instalações antigas do Windows
* outros layouts de disco

Portanto, o processo não deve depender do número atual de partições.

## Decisão importante

O projeto utiliza:

```text
Custom DiskPart Script
```

e não o particionamento automático do Windows Setup.

O script executa:

```text
SELECT DISK=0
CLEAN
CONVERT GPT
```

e depois cria o layout necessário para UEFI.

## Layout desejado

Preferencialmente:

```text
Disk 0 - GPT
│
├── EFI System Partition
│   └── ~300 MB FAT32
│
├── Microsoft Reserved
│   └── 16 MB
│
├── Windows
│   └── NTFS
│
└── Recovery
    └── ~1000 MB NTFS
```

O Windows instalado deve utilizar `C:` como unidade do sistema.

---

# 5. Disk Assertions

O projeto NÃO deve utilizar Disk Assertions que exijam que o disco esteja vazio.

O seguinte comportamento causou falha:

```text
Assert that there are no partitions on the target disk
```

Isso produzia:

```text
Running disk assertions
There are already X partitions on disk 0.
Fatal error: Disk assertion failed.
```

A configuração correta utilizada no projeto é:

```text
Make no assertions about the target disk
```

O motivo é que o próprio DiskPart executa:

```text
CLEAN
```

Portanto, a existência de partições anteriores é esperada.

## Segurança

Embora não sejam utilizadas assertions de partições, o projeto deve minimizar o risco de apagar o disco errado.

Antes de evoluir o projeto para produção, estudar mecanismos mais seguros de identificação do disco, como:

* capacidade
* modelo
* fabricante
* tipo de barramento
* número de série
* NVMe/SATA
* combinação de propriedades

Nunca assumir que `Disk 0` será obrigatoriamente o disco correto em todos os computadores.

---

# 6. Estrutura do projeto

Estrutura inicial desejada:

```text
windows-workstation-provisioning/
│
├── autounattend.xml
│
├── scripts/
│   ├── 00-init.ps1
│   ├── 10-windows-update.ps1
│   ├── 20-join-domain.ps1
│   ├── 30-install-apps.ps1
│   ├── 40-hardening.ps1
│   ├── 90-validation.ps1
│   └── 99-finish.ps1
│
├── installers/
│   ├── chrome/
│   ├── 7zip/
│   ├── vscode/
│   └── custom/
│
├── config/
│   ├── apps.json
│   ├── domain.json
│   └── deployment.json
│
├── logs/
│
├── docs/
│   ├── architecture.md
│   ├── installation.md
│   ├── troubleshooting.md
│   └── security.md
│
└── README.md
```

A estrutura pode evoluir durante o desenvolvimento.

---

# 7. PowerShell

PowerShell é a principal linguagem de automação pós-instalação.

Os scripts devem:

* possuir responsabilidade única
* ser idempotentes quando possível
* gerar logs
* retornar códigos de erro apropriados
* validar pré-requisitos
* evitar credenciais hardcoded
* evitar operações destrutivas sem confirmação/configuração explícita
* ser fáceis de executar individualmente para troubleshooting

Evitar colocar todo o código em um único `postinstall.ps1`.

---

# 8. Orquestração

Deve existir um script principal responsável por controlar o fluxo.

Exemplo:

```text
Deploy.ps1
```

Fluxo:

```text
Deploy.ps1
    │
    ├── Initialize
    │
    ├── Windows Update
    │
    ├── Reboot if required
    │
    ├── Domain Join
    │
    ├── Reboot
    │
    ├── Application Installation
    │
    ├── Configuration / Hardening
    │
    ├── Validation
    │
    └── Finish
```

O sistema precisa suportar reboot entre etapas.

Não assumir que um único processo PowerShell continuará executando depois de um reboot.

Utilizar mecanismo persistente de estado, por exemplo:

```text
C:\ProgramData\WorkstationProvisioning\
```

com um arquivo de estado.

Exemplo:

```text
state.json
```

Esse estado deve indicar qual etapa foi concluída.

---

# 9. Windows Update

O objetivo é verificar e instalar todas as atualizações disponíveis no momento do provisionamento.

O processo deve:

1. Detectar conectividade.
2. Detectar o estado do Windows Update.
3. Procurar atualizações.
4. Instalar atualizações.
5. Detectar necessidade de reboot.
6. Reiniciar quando necessário.
7. Retomar o processo.
8. Procurar atualizações novamente.
9. Repetir até que não existam mais atualizações aplicáveis ou até atingir um limite seguro.

Não assumir que uma única execução instala tudo.

O script deve registrar:

* quantidade de updates encontrados
* updates instalados
* erros
* necessidade de reboot
* resultado final

O uso de módulos externos, como `PSWindowsUpdate`, deve ser avaliado antes de ser adotado definitivamente.

Preferir mecanismos suportados pelo próprio Windows quando forem suficientes.

---

# 10. Domain Join

Depois da instalação e atualização do Windows, a máquina deverá entrar no domínio corporativo.

O domínio deve ser parametrizado através de configuração, e NÃO hardcoded dentro dos scripts.

Exemplo conceitual:

```json
{
    "domain": "empresa.local"
}
```

O processo deverá:

1. Validar conectividade.
2. Validar DNS.
3. Validar resolução do domínio.
4. Validar disponibilidade de controlador de domínio.
5. Executar Domain Join.
6. Validar o resultado.
7. Reiniciar.
8. Confirmar que a máquina está no domínio.

---

# 11. Credenciais

NUNCA armazenar:

```text
password: "senha"
```

no projeto.

Nunca colocar credenciais de domínio em:

* Git
* autounattend.xml
* JSON
* PowerShell
* README
* logs

O mecanismo de autenticação deve ser projetado de forma segura.

Possibilidades a avaliar:

* credencial fornecida interativamente
* conta de provisionamento limitada
* credencial protegida
* DPAPI quando aplicável
* mecanismo corporativo de secrets
* solução de deployment/MDM que não exija senha no script

A solução final deve considerar que o pendrive pode ser acessado fisicamente por terceiros.

---

# 12. Instalação de aplicações

O projeto deve permitir instalar aplicações após a instalação do Windows.

Exemplos:

```text
Google Chrome
7-Zip
Visual Studio Code
Aplicações corporativas
Ferramentas internas
```

Os instaladores podem ser:

```text
MSI
EXE
```

Cada aplicação deve possuir sua própria configuração.

Preferencialmente utilizar:

```text
installers/
    chrome/
    7zip/
    vscode/
```

e uma configuração central:

```text
config/apps.json
```

Exemplo conceitual:

```json
{
    "applications": [
        {
            "name": "Google Chrome",
            "type": "msi",
            "installer": "installers/chrome/chrome.msi",
            "arguments": "/qn /norestart",
            "required": true
        }
    ]
}
```

O sistema deve:

* verificar se o programa já está instalado
* evitar reinstalação desnecessária
* executar instalação silenciosa
* validar exit code
* registrar logs
* continuar ou interromper de acordo com `required`

---

# 13. Download de aplicações

Também pode existir suporte para baixar instaladores da Internet.

Porém:

* usar somente fontes oficiais
* utilizar HTTPS
* validar download
* preferir versões Enterprise/Offline quando disponíveis
* evitar depender de páginas HTML frágeis
* considerar checksum/hash quando possível
* registrar versão instalada

Não assumir que uma URL de download permanecerá permanente.

---

# 14. Configurações pós-instalação

O projeto poderá posteriormente automatizar:

* nome do computador
* fuso horário
* Windows Firewall
* configurações de rede
* políticas locais
* energia
* serviços
* registro
* aplicações padrão
* remoção de bloatware
* configurações corporativas
* certificados
* VPN
* impressoras
* mapeamento de recursos
* configurações de navegador

Essas funcionalidades devem ficar separadas em módulos/scripts específicos.

---

# 15. Hardening

O hardening será uma etapa independente.

Exemplos:

```text
40-hardening.ps1
```

Possíveis tarefas:

* Windows Firewall
* políticas de senha locais
* serviços desnecessários
* SMB
* TLS
* Defender
* configurações de segurança
* políticas locais

Não implementar alterações de segurança sem documentar:

1. O que será alterado.
2. Por que será alterado.
3. Impacto.
4. Como reverter.

---

# 16. Validação final

Antes de considerar o computador pronto, executar uma etapa:

```text
90-validation.ps1
```

Ela deve validar:

### Sistema

* Windows instalado corretamente
* versão/build
* arquitetura
* ativação, quando aplicável

### Rede

* conectividade
* DNS
* gateway
* Internet

### Domínio

* computador no domínio
* domínio correto
* controlador acessível

### Updates

* Windows Update funcionando
* nenhum update crítico pendente, conforme critério definido

### Aplicações

* aplicações obrigatórias instaladas
* versões corretas

### Segurança

* Firewall
* Defender
* BitLocker, se configurado

A validação deve gerar um relatório.

---

# 17. Logs

Todos os scripts devem registrar informações em:

```text
C:\ProgramData\WorkstationProvisioning\Logs\
```

Exemplo:

```text
deployment.log
windows-update.log
domain-join.log
applications.log
validation.log
```

Os logs não podem conter:

* senhas
* tokens
* secrets
* hashes de credenciais
* informações sensíveis desnecessárias

O log deve facilitar troubleshooting.

---

# 18. Idempotência

Sempre que possível, os scripts devem poder ser executados novamente sem causar problemas.

Exemplo:

```powershell
if (Chrome already installed) {
    skip
}
```

Em vez de:

```powershell
install Chrome again
```

O mesmo vale para:

* configurações
* serviços
* tarefas agendadas
* domínio
* diretórios
* registro

---

# 19. Tratamento de erros

Cada etapa deve:

1. Validar pré-requisitos.
2. Executar operação.
3. Validar resultado.
4. Registrar sucesso ou erro.
5. Definir exit code.
6. Decidir se o deployment deve continuar.

Erros críticos devem interromper o deployment.

Erros não críticos devem ser registrados e tratados conforme configuração.

Evitar:

```powershell
try {
    ...
} catch {
    # ignore
}
```

Erros nunca devem ser silenciosamente ignorados.

---

# 20. Reboots

Reboots são parte normal do processo.

Principalmente após:

* Windows Update
* Domain Join
* determinadas instalações de software

O deployment deve sobreviver a múltiplos reboots.

O estado deve ser persistido antes do reboot.

Exemplo:

```text
State = WindowsUpdateCompleted
```

Depois do reboot:

```text
Read State
Continue from next stage
```

---

# 21. Limpeza final

Depois que o provisionamento terminar:

* remover scripts temporários
* remover instaladores temporários
* remover credenciais protegidas temporárias
* remover tarefas agendadas temporárias
* manter apenas logs necessários
* registrar status final

Não apagar logs imediatamente se eles forem necessários para auditoria/troubleshooting.

---

# 22. Segurança

Este projeto executará operações altamente privilegiadas.

Portanto:

* Nunca confiar em arquivos externos sem validação.
* Nunca armazenar senhas em texto plano.
* Não executar scripts baixados arbitrariamente.
* Preferir fontes oficiais.
* Validar executáveis.
* Considerar hash dos instaladores.
* Usar `-ErrorAction Stop` quando apropriado.
* Validar caminhos.
* Evitar comandos destrutivos fora do contexto esperado.

O `DiskPart CLEAN` é uma operação destrutiva e deve permanecer explicitamente direcionado ao disco correto.

---

# 23. Filosofia arquitetural

O projeto deve seguir esta separação:

```text
autounattend.xml
        │
        │ bootstrap
        ▼
PowerShell Orchestrator
        │
        ├── System Configuration
        ├── Windows Update
        ├── Domain Join
        ├── Application Installation
        ├── Security / Hardening
        ├── Validation
        └── Cleanup
```

O XML não deve concentrar lógica de negócio.

PowerShell deve conter a lógica.

Configuração deve ficar separada da implementação.

Instaladores devem ficar separados dos scripts.

Logs devem ficar separados da configuração.

---

# 24. Roadmap de implementação

Implementar em fases.

## Fase 1 — Base

* [ ] Estrutura de diretórios
* [ ] README
* [ ] autounattend.xml
* [ ] DiskPart
* [ ] instalação Windows
* [ ] logging básico

## Fase 2 — Orquestração

* [ ] Deploy.ps1
* [ ] state.json
* [ ] controle de etapas
* [ ] tratamento de reboot
* [ ] tratamento de erros

## Fase 3 — Windows Update

* [ ] detectar updates
* [ ] instalar updates
* [ ] detectar reboot
* [ ] retomar após reboot
* [ ] validar estado final

## Fase 4 — Domain Join

* [ ] validar rede
* [ ] validar DNS
* [ ] validar domínio
* [ ] executar join
* [ ] reboot
* [ ] validar domínio

## Fase 5 — Aplicações

* [ ] apps.json
* [ ] instalador MSI
* [ ] instalador EXE
* [ ] instalação silenciosa
* [ ] detecção de software existente
* [ ] validação
* [ ] logs

## Fase 6 — Configuração

* [ ] hostname
* [ ] timezone
* [ ] configurações corporativas
* [ ] firewall
* [ ] Defender
* [ ] configurações de rede

## Fase 7 — Hardening

* [ ] definir baseline
* [ ] implementar políticas
* [ ] documentar alterações
* [ ] validar segurança

## Fase 8 — Validation

* [ ] system validation
* [ ] network validation
* [ ] domain validation
* [ ] application validation
* [ ] Windows Update validation
* [ ] security validation
* [ ] relatório final

## Fase 9 — Cleanup

* [ ] remover secrets temporários
* [ ] remover arquivos temporários
* [ ] remover tarefas temporárias
* [ ] preservar logs necessários
* [ ] status final

## Fase 10 — Testes

Testar pelo menos:

1. PC com disco completamente vazio.
2. PC com várias partições OEM.
3. PC com múltiplas Recovery partitions.
4. PC com Windows previamente instalado.
5. PC sem Internet.
6. PC com DNS incorreto.
7. Falha durante Windows Update.
8. Reboot durante deployment.
9. Falha no Domain Join.
10. Software já instalado.
11. Instalador inválido.
12. Segundo disco presente.
13. Pendrive como Disk 0.
14. Disco NVMe.
15. Disco SATA.

---

# 25. Regras para o Claude Code

Ao trabalhar neste projeto:

1. Primeiro analisar a estrutura existente antes de criar arquivos.
2. Não substituir arquivos existentes sem entender sua função.
3. Não alterar `autounattend.xml` sem verificar o impacto no Windows Setup.
4. Não adicionar credenciais reais.
5. Não hardcodar senhas.
6. Não assumir que Disk 0 é sempre o disco correto sem documentar essa decisão.
7. Manter scripts pequenos e com responsabilidade única.
8. Preferir funções reutilizáveis.
9. Adicionar logs.
10. Adicionar tratamento de erros.
11. Considerar reboot em qualquer operação que possa reiniciar o sistema.
12. Tornar scripts idempotentes quando possível.
13. Não baixar software de fontes desconhecidas.
14. Não executar comandos destrutivos durante testes sem deixar explícito o alvo.
15. Atualizar documentação quando a arquitetura mudar.
16. Antes de implementar uma nova funcionalidade, explicar brevemente onde ela se encaixa na arquitetura.
17. Não criar abstrações desnecessárias; priorizar código simples e legível.
18. Sempre considerar execução como Administrator/SYSTEM.
19. Não colocar secrets no Git.
20. Ao terminar uma implementação, informar:

* arquivos criados/alterados
* funcionamento
* como testar
* riscos/limitações
* próximo passo recomendado.

---

# 26. Objetivo final

O resultado esperado é um mecanismo de provisioning capaz de transformar:

```text
PC novo / PC formatado
        │
        ▼
Pendrive Windows
        │
        ▼
Autounattend
        │
        ▼
Windows 11 Pro
        │
        ▼
Windows Update
        │
        ▼
Domain Join
        │
        ▼
Aplicações
        │
        ▼
Configurações
        │
        ▼
Hardening
        │
        ▼
Validation
        │
        ▼
PC pronto para entrega
```

O projeto deve ser suficientemente modular para que novas aplicações, configurações e etapas possam ser adicionadas sem reescrever todo o processo.


# Instruções do Projeto

## Linguagem

* PowerShell 7+
* Comentários e documentação devem ser escritos em português.
* Mensagens exibidas ao usuário devem ser escritas em português.
* Nomes de funções, variáveis, parâmetros, classes, propriedades e métodos devem seguir as convenções de nomenclatura definidas neste documento.
* Os nomes técnicos do PowerShell e das APIs devem permanecer em inglês quando fizerem parte da própria tecnologia.

---

## Convenções de Nomenclatura

### Funções

As funções DEVEM utilizar o padrão de nomenclatura `Verb-Noun` do PowerShell.

Sempre que possível, utilizar verbos aprovados pelo PowerShell.

Exemplos:

* `Install-Software`
* `Test-NetworkConnection`
* `Get-ComputerInfo`
* `Set-WindowsConfiguration`
* `Join-ComputerToDomain`

NÃO utilizar:

* `installSoftware`
* `install_software`
* `InstallSoftware`
* `install-software`

Para consultar os verbos aprovados pelo PowerShell:

```powershell
Get-Verb
```

---

### Variáveis

Utilizar `camelCase` para variáveis locais.

Exemplos:

```powershell
$computerName
$softwareName
$installationPath
$isInstalled
$hasInternet
$shouldRestart
```

Evitar:

```powershell
$Computer_Name
$computer_name
$ComputerName
$computer-name
```

---

### Parâmetros

Utilizar `PascalCase` para parâmetros de funções.

Exemplos:

```powershell
[string]$ComputerName
[string]$InstallationPath
[switch]$Force
[int]$TimeoutSeconds
```

Uso:

```powershell
Install-Software -InstallationPath "C:\Install\Chrome.msi" -Force
```

---

### Classes

Utilizar `PascalCase` para nomes de classes.

Exemplos:

* `SoftwarePackage`
* `InstallationResult`
* `ComputerConfiguration`
* `WindowsConfiguration`

Exemplo:

```powershell
class SoftwarePackage {
}
```

---

### Propriedades

Utilizar `PascalCase` para propriedades.

Exemplos:

```powershell
$ComputerName
$InstallationPath
$Version
$OperatingSystem
```

Exemplo:

```powershell
class ComputerInfo {
    [string]$ComputerName
    [string]$OperatingSystem
    [string]$Version
}
```

---

### Métodos

Utilizar `PascalCase` para métodos.

Exemplos:

```powershell
Install()
Uninstall()
TestInstallation()
GetVersion()
```

---

### Variáveis booleanas

Variáveis que representam valores booleanos devem utilizar nomes que expressem claramente uma condição.

Preferir prefixos como:

* `is`
* `has`
* `can`
* `should`

Exemplos:

```powershell
$isInstalled
$isConnected
$isAdministrator
$hasInternet
$hasError
$canInstall
$shouldRestart
```

Evitar nomes ambíguos como:

```powershell
$installed
$connection
$status
```

quando o objetivo for representar diretamente uma condição booleana.

---

## Nomenclatura de Arquivos

Scripts PowerShell devem utilizar `PascalCase` ou o padrão `Verb-Noun`.

Preferir nomes que expressem claramente a responsabilidade do arquivo.

Exemplos:

* `Install-Software.ps1`
* `Configure-Windows.ps1`
* `Join-Domain.ps1`
* `Install-WindowsUpdates.ps1`
* `Configure-Network.ps1`

Evitar nomes genéricos quando um nome mais específico representar melhor a responsabil
