# Diagnóstico da máquina de teste. SOMENTE LEITURA: não altera nada no sistema.
# Coleta o necessário para investigar:
#   - login automático após o ingresso no domínio (Winlogon, aviso legal, logons com falha, reinícios);
#   - softwares corporativos instalados (nomes em Programas e Recursos, versão do Office, pastas do BDE);
#   - logs do instalador do WithSecure (modo silencioso).
# Senhas não são lidas nem gravadas.
#
# Como usar (PowerShell como Administrador, para ler o log de Segurança):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\tools\Get-ProvisioningDiagnostic.ps1
# Resultado: na tela e em <pendrive>\logs\diagnostico-<computador>-<data>.txt

param([int] $Days = 3)

$since  = (Get-Date).AddDays(-$Days)
$outDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir ('diagnostico-{0}-{1:yyyyMMdd-HHmm}.txt' -f $env:COMPUTERNAME, (Get-Date))

function Write-Section {
    param([string] $Title)
    "`n==== $Title ===="
}

function Get-LogonFailureReason {
    param([string] $SubStatus)
    switch ($SubStatus.ToLowerInvariant()) {
        '0xc0000064' { 'usuário não existe (domínio/nome errado no login automático?)' }
        '0xc000006a' { 'senha incorreta' }
        '0xc0000072' { 'conta desativada' }
        '0xc0000234' { 'conta bloqueada' }
        '0xc0000071' { 'senha expirada' }
        '0xc0000193' { 'conta expirada' }
        '0xc000015b' { 'tipo de logon não permitido' }
        default      { '' }
    }
}

& {
    Write-Section 'Computador'
    $cs = Get-CimInstance Win32_ComputerSystem
    'Nome: {0} | Domínio: {1} | No domínio: {2} | Usuário atual: {3}' -f $cs.Name, $cs.Domain, $cs.PartOfDomain, $env:USERNAME
    'Último boot: {0}' -f (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

    Write-Section 'Login automático (Winlogon, sem senha)'
    $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    foreach ($name in 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'AltDefaultDomainName', 'AutoLogonCount', 'ForceAutoLogon', 'AutoLogonChecked') {
        $property = $winlogon.PSObject.Properties[$name]
        '{0} = {1}' -f $name, $(if ($property) { $property.Value } else { '(não existe)' })
    }
    'DefaultPassword em texto no registro: {0}' -f [bool] $winlogon.PSObject.Properties['DefaultPassword']

    Write-Section 'Aviso legal e políticas de logon (GPO)'
    $system = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    foreach ($name in 'legalnoticecaption', 'legalnoticetext', 'DontDisplayLastUserName', 'DisableCAD') {
        $property = $system.PSObject.Properties[$name]
        '{0} = [{1}]' -f $name, $(if ($property) { $property.Value } else { '(não existe)' })
    }

    Write-Section "Logons com falha (evento 4625, últimos $Days dias)"
    try {
        $failures = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $since } -ErrorAction Stop)
        foreach ($event in $failures | Select-Object -First 30) {
            $xml = [xml] $event.ToXml()
            $data = @{}; foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
            '{0:dd/MM HH:mm:ss} conta={1}\{2} tipo={3} status={4} sub={5} {6} processo={7}' -f $event.TimeCreated,
                $data.TargetDomainName, $data.TargetUserName, $data.LogonType, $data.Status, $data.SubStatus,
                (Get-LogonFailureReason $data.SubStatus), $data.ProcessName
        }
        if ($failures.Count -eq 0) { 'Nenhum.' }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { 'Nenhum.' }
        else { "Não foi possível ler (rode como Administrador): $($_.Exception.Message)" }
    }

    Write-Section "Logons interativos com sucesso (evento 4624, tipo 2, últimos $Days dias)"
    try {
        $logons = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = $since } -ErrorAction Stop |
            Where-Object { $_.Properties[8].Value -eq 2 } | Select-Object -First 30)
        foreach ($event in $logons) {
            '{0:dd/MM HH:mm:ss} conta={1}\{2}' -f $event.TimeCreated, $event.Properties[6].Value, $event.Properties[5].Value
        }
        if ($logons.Count -eq 0) { 'Nenhum.' }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { 'Nenhum.' }
        else { "Não foi possível ler (rode como Administrador): $($_.Exception.Message)" }
    }

    Write-Section "Reinícios e desligamentos (evento 1074, últimos $Days dias)"
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074; StartTime = $since } -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { '{0:dd/MM HH:mm:ss} {1}' -f $_.TimeCreated, ($_.Message -replace '\s+', ' ') }

    Write-Section 'Programas instalados (Office, WithSecure, BDE, Borland, Everest)'
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '(?i)office|microsoft 365|withsecure|f-secure|bde|borland|everest|database engine' } |
        Sort-Object DisplayName | ForEach-Object { '{0} | versão {1} | {2} | {3}' -f $_.DisplayName, $_.DisplayVersion, $_.Publisher, $_.PSChildName }

    Write-Section 'Office'
    $word = 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE'
    if (Test-Path -LiteralPath $word) { 'WINWORD.EXE versão {0}' -f (Get-Item -LiteralPath $word).VersionInfo.FileVersion } else { 'WINWORD.EXE não encontrado.' }
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r) { 'ClickToRun: produtos={0} versão={1} canal={2}' -f $c2r.ProductReleaseIds, $c2r.VersionToReport, $c2r.CDNBaseUrl }

    Write-Section 'BDE (registro)'
    $bde = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Borland\Database Engine' -ErrorAction SilentlyContinue
    if ($bde) { 'DLLPATH = {0} | CONFIGFILE01 = {1}' -f $bde.DLLPATH, $bde.CONFIGFILE01 } else { 'Borland\Database Engine não existe no registro.' }

    Write-Section 'Pastas do BDE e do Everest'
    foreach ($path in 'C:\Program Files (x86)\Borland\Common Files\BDE', 'C:\Program Files (x86)\Common Files\Borland Shared\BDE', 'C:\everest1', 'C:\Exec_Laquila', 'C:\Users\Public\Desktop') {
        if (Test-Path -LiteralPath $path) {
            "$path :"
            Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -First 25 |
                ForEach-Object { '    {0}  {1:dd/MM/yyyy HH:mm}' -f $_.Name, $_.LastWriteTime }
        }
        else { "$path : não existe" }
    }
    'Pastas com BDE no nome em Program Files (x86):'
    Get-ChildItem 'C:\Program Files (x86)' -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '(?i)bde|borland' |
        ForEach-Object { '    ' + $_.FullName }

    Write-Section "Logs do instalador do WithSecure (últimos $Days dias)"
    $roots = @('C:\ProgramData\F-Secure', 'C:\ProgramData\WithSecure', 'C:\Windows\Temp') + @(Get-ChildItem 'C:\Users\*\AppData\Local\Temp' -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $logs = foreach ($root in $roots | Where-Object { Test-Path -LiteralPath $_ }) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.log', '*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since -and $_.Length -lt 20MB }
    }
    $found = $false
    foreach ($log in $logs) {
        $lines = @(Select-String -LiteralPath $log.FullName -Pattern 'SILENT parameter|command line|cmdline|--silent|Exiting with code|client_install|conflict|Running without GUI' -ErrorAction SilentlyContinue | Select-Object -First 15)
        if ($lines.Count -gt 0) {
            $found = $true
            "$($log.FullName):"
            $lines | ForEach-Object { '    ' + $_.Line.Trim() }
        }
    }
    if (-not $found) { 'Nenhum log do instalador encontrado.' }

    Write-Section 'Log do provisionamento (login automático, domínio e softwares corporativos)'
    $deployLog = 'C:\ProgramData\WorkstationProvisioning\Logs\deployment.log'
    if (Test-Path -LiteralPath $deployLog) {
        Select-String -LiteralPath $deployLog -Pattern '(?i)login automático|ingresso|reinici|domínio|corporativ|WithSecure|BDE|Office|ERRO|FALHA|AVISO' |
            Select-Object -Last 80 | ForEach-Object { $_.Line }
    }
    else { 'deployment.log não encontrado.' }
} *>&1 | Tee-Object -FilePath $outFile

Write-Host ''
Write-Host "Diagnóstico salvo em: $outFile" -ForegroundColor Green
