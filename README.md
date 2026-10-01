# Automated Workstation Provisioning

Automação modular para instalação e configuração de estações Windows.

## Organização

Cada etapa fica em um script independente dentro de `scripts\`. O orquestrador inicia cada etapa em um processo PowerShell separado, com:

- log individual por etapa em `logs`;
- reexecução segura de etapas concluídas;
- modo de simulação como padrão;
- falha explícita: uma etapa com erro interrompe o fluxo.


Os arquivos `autounattend.xml` continuam responsáveis pela instalação do Windows e particionamento. A camada modular deve ser executada após a instalação, sem misturar lógica de particionamento com configuração pós-instalação.

