# Instalação de aplicativos

Data: 2026-10-15

Status: **implementado.** Testado com testes de unidade e com download real (seção 9). **A instalação real ainda precisa ser testada em VM.**

Corresponde à **Fase 5** do roadmap do CLAUDE.md.

---

## 1. Decisões

| # | Decisão | Resultado |
|---|---|---|
| P1 | Como obter os instaladores | **A:** download do site oficial, com validação. **D como reserva:** cópia no pendrive. |
| P1b | Onde fica a reserva | **(b) Copiada para o disco** na primeira execução (`C:\ProgramData\WorkstationProvisioning\installers\`), para funcionar mesmo sem o pendrive depois dos reboots |
| P2 | Programas obrigatórios | **Chrome, 7-Zip e VLC são obrigatórios** (`"required": true`) |
| — | Falhas na tela | Todos os programas são tentados. O resumo mostra as falhas **em vermelho**, com o motivo. Só então, se algum obrigatório falhou, o provisionamento é interrompido. |
| — | Formato do instalador | **MSI** para os três: instalação silenciosa e códigos de saída padronizados. **EXE** também é aceito para programas futuros, com os argumentos silenciosos informados no `apps.json`. |

---

## 2. Onde se encaixa

```text
Start-Provisioning
  ├─ 1. Login automático
  ├─ 2. Verificação de internet
  ├─ 3. Windows Update (ciclos e reboots)
  └─ 4. Aplicativos  ← scripts\Install-Applications.ps1, lista em config\apps.json
```

Na primeira execução, a partir do pendrive, o orquestrador copia para `C:\ProgramData\WorkstationProvisioning\`:

- `scripts\`;
- `config\apps.json`;
- `installers\`.

O `config\autologon.txt` **não** é copiado.

---

## 3. Programas (`config\apps.json`)

| Programa | Versão | Instalador | Validação | Como detecta se já está instalado |
|---|---|---|---|---|
| Google Chrome | sempre a atual | `https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi` | Assinatura digital de **`Google LLC`** | Nome `Google Chrome` |
| 7-Zip | 26.04 | `https://www.7-zip.org/a/7z2604-x64.msi` | SHA-256 `0B01334A418654293513449F61D6BFC99E5196CA371E3C3DC961EDA57CD535C6` | Nome `7-Zip*` |
| VLC | 3.0.24 | `https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/vlc-3.0.24-win64.msi` | SHA-256 `22172095CE4C2D5F5B600BB4C142D78105DB29A77FA59A931941876F3B20F6D0` | Nome `VLC media player*` |

De onde vieram os dados (2026-10-15):

- **7-Zip e VLC:** versões, endereços e hashes dos **manifestos oficiais do winget** (`github.com/microsoft/winget-pkgs`), que apontam para o site do fabricante e têm o hash validado pela Microsoft.
- **Chrome:** assinatura conferida num download real (`Get-AuthenticodeSignature`: `Valid`, `CN=Google LLC`).

### Campos de cada aplicativo

| Campo | Obrigatório | Descrição |
|---|---|---|
| `id` | sim | Identificador curto. Também é o nome da pasta de reserva em `installers\<id>\` |
| `name` | sim | Nome exibido na tela e no log |
| `type` | sim | `msi` ou `exe` |
| `url` | sim | Endereço oficial, **somente HTTPS** |
| `fileName` | sim | Nome do arquivo, no download e na reserva |
| `arguments` | MSI: não (padrão `/qn /norestart`); EXE: **sim** | Argumentos de instalação silenciosa |
| `sha256` | `sha256` e/ou `signer` | Hash esperado do instalador |
| `signer` | `sha256` e/ou `signer` | Nome (CN) de quem assina o instalador |
| `displayName` | sim | Nome em "Programas e Recursos"; aceita curinga (`*`) |
| `required` | sim | `true` interrompe o provisionamento se falhar; `false` só gera aviso |
| `successExitCodes` | não (só EXE) | Códigos de saída de sucesso. Padrão: `0` e `3010`. |

---

## 4. Funcionamento de cada aplicativo

```text
já instalado?                          → pula ("[JÁ HAVIA]")
download oficial (HTTPS, 3 tentativas) → valida hash/assinatura
   falhou ou inválido?                 → AVISO na tela e usa installers\<id>\<arquivo> (mesma validação)
   reserva ausente ou inválida?        → FALHA (com os dois motivos)
instala em modo silencioso             → MSI: msiexec /i … /qn /norestart /l*v Logs\msi-<id>.log
   1618 (outra instalação em andamento)? → aguarda 30 s e tenta de novo (até 10 vezes)
   código de saída de erro?            → FALHA
confere se passou a aparecer instalado → senão, FALHA
apaga o instalador baixado (a reserva é mantida)
```

Resumo na janela ao final (exemplo):

```text
Resumo dos aplicativos:
  [OK]         Google Chrome - instalado (origem: download)
  [JÁ HAVIA]   7-Zip - já estava instalado
  [FALHA]      VLC media player - download: …; pendrive: arquivo não encontrado (…)   ← vermelho
ERRO: aplicativo(s) obrigatório(s) não instalado(s): VLC media player. …            ← vermelho
```

Na janela do provisionamento:

- linhas com `[FALHA]`, `FALHA:` ou começando com `ERRO` aparecem **em vermelho**;
- linhas começando com `AVISO` aparecem **em amarelo**.

Isso vale para todas as etapas, inclusive o Windows Update.

**Exit codes:**

- `0`: todos os obrigatórios instalados, ou já presentes;
- `1`: falha num obrigatório ou erro no `apps.json`. Interrompe o provisionamento.

Para tentar de novo, basta logoff e login: os programas já instalados são pulados.

---

## 5. ⚠️ Inspeção SSL do firewall da empresa

**Encontrado em 2026-10-15:** o firewall da empresa (**Fortinet**) inspeciona as conexões HTTPS com **`7-zip.org`** e **`videolan.org`**. Ele apresenta um certificado próprio (`O=Fortinet`, `CN=FG200FT923925783`), que **não é confiável** numa máquina sem o certificado raiz do Fortinet. O Google não é inspecionado.

**Consequência nesta rede:**

- o download do **7-Zip e do VLC falha** (mensagem: "provável inspeção SSL do firewall da rede");
- sem a reserva no pendrive, os dois falham, e o provisionamento é interrompido, porque são obrigatórios.

**A verificação de certificado não é desligada:** isso permitiria instalar arquivos adulterados.

**Soluções possíveis** (decidir com a infraestrutura):

| Solução | Observação |
|---|---|
| **Colocar os instaladores no pendrive** (`installers\7zip\`, `installers\vlc\`) | Funciona já. É a reserva D. |
| Pedir à infraestrutura uma **exceção de inspeção SSL** para `7-zip.org` e `download.videolan.org` | O download oficial passa a funcionar |
| **Instalar o certificado raiz do Fortinet** como etapa do provisionamento (certificado público, sem segredo) | Resolve também para outros sites inspecionados. É configuração corporativa (Fase 6). |
| Usar a rede de provisionamento sem inspeção SSL | Depende da infraestrutura |

---

## 6. Estrutura no pendrive

```text
<pendrive>\
├── scripts\                     ← todos os scripts
├── config\
│   ├── apps.json                ← lista de aplicativos (copiada para o disco)
│   └── autologon.txt            ← senha do login automático (NÃO é copiado)
└── installers\                  ← reserva (copiada para o disco)
    ├── chrome\googlechromestandaloneenterprise64.msi
    ├── 7zip\7z2604-x64.msi
    └── vlc\vlc-3.0.24-win64.msi
```

**A reserva precisa ser a mesma versão do `apps.json`** quando a validação é por hash (7-Zip e VLC). Para o Chrome, validado pela assinatura, qualquer versão oficial serve.

---

## 7. Como atualizar a versão de um programa

1. Pegue a nova versão, o endereço do MSI x64 e o SHA-256 no manifesto do winget: `github.com/microsoft/winget-pkgs/tree/master/manifests/7/7zip/7zip/<versão>` ou `.../v/VideoLAN/VLC/<versão>`, arquivo `*.installer.yaml`, bloco `Architecture: x64` + `InstallerType: wix`.
2. Atualize `url`, `fileName` e `sha256` no `config\apps.json`.
3. Substitua o arquivo em `installers\<id>\` no pendrive pela mesma versão.
4. Rode os testes (`Invoke-Pester .\tests\Unit`): um deles valida o `apps.json` real.

---

## 8. Arquivos

| Arquivo | Ação |
|---|---|
| `scripts\Install-Applications.ps1` | Novo. Substitui o `Install-Programs.ps1`, que era um rascunho quebrado (chamava a si mesmo). |
| `config\apps.json` | Preenchido com os três programas |
| `scripts\Start-Provisioning.ps1` | Etapa 4; cópia do `apps.json` e dos `installers\`; cores para falhas e avisos das etapas |
| `tests\Unit\Install-Applications.Tests.ps1` | Novo: 46 testes |

---

## 9. Testes realizados (2026-10-15, Windows PowerShell 5.1)

| Teste | Resultado |
|---|---|
| Testes de unidade (`Install-Applications.Tests.ps1`) | ✅ 46 testes. Inclui a validação do `config\apps.json` real. |
| Prova de eficácia (4 defeitos inseridos de propósito: sem reserva, sem validação, aceitar HTTP, parar no primeiro erro) | ✅ Todos detectados |
| **Download real + validação**, sem instalar, nesta rede | ✅ Chrome baixado (162 MB) e validado pela assinatura. ⚠️ 7-Zip e VLC bloqueados pela inspeção SSL (seção 5); a reserva foi procurada como esperado. |
| Orquestrador com as 4 etapas (etapas simuladas) | ✅ Copia `apps.json` e `installers\` e **não** o `autologon.txt`. Falha de obrigatório interrompe com as linhas em vermelho e preserva o estado. |

**Ainda não testado (fazer em VM):**

- instalação real dos três MSI;
- detecção depois da instalação;
- comportamento com outra instalação em andamento (1618).

---

## 10. Riscos e limitações

- **Inspeção SSL** (seção 5): sem reserva no pendrive ou exceção no firewall, o 7-Zip e o VLC não são instalados nesta rede.
- **Versões fixas** (7-Zip, VLC): o `apps.json` e a reserva precisam ser atualizados manualmente (seção 7). O Chrome sempre baixa a versão atual e se atualiza sozinho depois.
- **Programa já instalado em versão antiga** é considerado instalado: a etapa não atualiza programas.
- **Reboot pedido por um MSI** (3010) é só registrado. Não reinicia a máquina.
- **Arquivos na máquina:** a reserva copiada para `C:\ProgramData\...\installers\` (cerca de 200 MB) fica até a limpeza final (Fase 9).
