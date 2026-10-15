# Configuração dos arquivos autounattend.xml

Última atualização: 2026-10-02

Comparação entre as 5 variantes de `autounattend.xml` em `Arquivos de autounattend\`. Os problemas encontrados em cada uma estão em [autounattend_errors_verify.md](autounattend_errors_verify.md).

## Comparativo

Na tabela, **`SI\`** abrevia `Arquivos de autounattend\Sem interação com partição de disco\`. Todos os arquivos se chamam `autounattend.xml`.

| Caminho | Particionamento | Verifica o disco antes? | Continua se o disco já tem partições? | Chama o `Start-Provisioning.ps1`? | Remove apps desnecessários? | Observações |
|---|---|---|---|---|---|---|
| `Arquivos de autounattend\` (raiz) | Manual: o técnico escolhe a partição na tela | Não | Sim, depois da escolha manual | ✅ Sim | ❌ Não | Única com chave de produto (a genérica de instalação do Pro). Não é totalmente automática. |
| `SI\MBR\` | Automático, **MBR**, com partição Recovery | Sim | ❌ Não, falha com erro | ❌ Não | ❌ Não | Incompatível com UEFI e Windows 11. |
| `SI\GPT\` | Automático, **GPT**, com o layout padrão do gerador | Sim | ❌ Não, falha com erro | ❌ Não | ❌ Não | — |
| `SI\GPT\Custom diskpart\` | **Diskpart do projeto**, GPT: EFI 300 MB, MSR 16 MB, Windows, Recovery ~1000 MB | Sim | ❌ Não, falha com erro | ❌ Não | ❌ Não | Esta é a falha registrada no CLAUDE.md. |
| `SI\GPT\Custom diskpart\No Assertions about the disk\` | **Diskpart do projeto**, GPT, mesmo layout do anterior | Não | ✅ Sim, apaga o Disk 0 inteiro | ✅ Sim | ✅ Sim: apps Xbox e Game DVR | **Padrão segundo o CLAUDE.md.** Única variante totalmente automática que chama o `Start-Provisioning.ps1`. |

**Atenção:** as variantes automáticas sempre usam o Disk 0, sem confirmar se é o disco certo. Na variante que não verifica o disco, isso significa que o Disk 0 é apagado mesmo que seja o pendrive ou um segundo disco.

## Configurações comuns a todos

- Idioma, teclado e região: pt-BR, ABNT2, Brasil.
- Edição: Windows 11 Pro (amd64).
- Contas: apenas `Laquila` (Administrators), com senha temporária de provisionamento em Base64 (`PlainText=false`).
- Login automático: `Laquila`, válido para 1 logon.
- Nome do computador: aleatório.
- Fuso horário: implícito (deduzido pela região).
- Primeiro logon: executa `C:\Windows\Setup\Scripts\First-Logon.ps1`, que:
  - zera o `AutoLogonCount`;
  - apaga o `unattend.xml` de `C:\Windows\Panther`;
  - nas variantes que chamam o `Start-Provisioning.ps1`, procura `scripts\Start-Provisioning.ps1` no pendrive e o abre em uma janela própria e visível, que mostra a etapa atual do provisionamento.

## Uso no pendrive

O Windows Setup só reconhece o arquivo se ele se chamar exatamente `autounattend.xml` e estiver na **raiz** do pendrive. O Windows não procura dentro de pastas.

Na pasta do projeto, os arquivos e pastas podem ter qualquer nome. Ao preparar o pendrive:

1. Copie **apenas uma** variante para a raiz do pendrive, com o nome `autounattend.xml`.
2. Copie a pasta `scripts\` para a raiz do pendrive. É de lá que o primeiro logon executa o `Start-Provisioning.ps1`.
3. Crie `config\autologon.txt` na raiz do pendrive, com a senha temporária da conta em Base64. Ele permite que o Windows entre sozinho na conta após cada reboot. Como gerar: `docs\planejamento-login-automatico.md`, seção 5. **Crie direto no pendrive**, nunca na pasta do projeto. Sem esse arquivo, o técnico faz login manualmente após cada reboot.
