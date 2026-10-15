# Login automático da conta do técnico durante o provisionamento.
# Carregado pelo Start-Provisioning.ps1 (dot-source). Decisões L1 a L4 em docs\planejamento-login-automatico.md.
#
# Um script não consegue fazer login sozinho: depois de um reboot nenhum script do projeto está rodando.
# Estas funções configuram o login automático do próprio Windows (Winlogon) ANTES de cada reboot,
# valendo para um único boot.
#
# A senha:
#   - é lida UMA vez do arquivo config\autologon.txt do pendrive (conteúdo em Base64);
#   - é guardada como segredo protegido do Windows (LSA), nunca em texto puro no registro;
#   - é apagada ao final do provisionamento.
#
# Exige execução como administrador. Compatível com Windows PowerShell 5.1.

$autoLogonSecretKey = 'L$WorkstationProvisioning_AutoLogon'   # segredo LSA local com a senha do provisionamento
$winlogonSecretKey  = 'DefaultPassword'                       # segredo LSA lido pelo Windows no login automático
$winlogonKey        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Add-AutoLogonNativeMethod {
    if ('WorkstationProvisioning.LsaSecret' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WorkstationProvisioning
{
    // Segredos protegidos do Windows (LSA private data).
    public static class LsaSecret
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct LSA_UNICODE_STRING
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LSA_OBJECT_ATTRIBUTES
        {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public int Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [DllImport("advapi32.dll")]
        private static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES objectAttributes, uint desiredAccess, out IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaStorePrivateData(IntPtr policyHandle, ref LSA_UNICODE_STRING keyName, IntPtr privateData);

        [DllImport("advapi32.dll")]
        private static extern uint LsaRetrievePrivateData(IntPtr policyHandle, ref LSA_UNICODE_STRING keyName, out IntPtr privateData);

        [DllImport("advapi32.dll")]
        private static extern uint LsaClose(IntPtr objectHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaFreeMemory(IntPtr buffer);

        [DllImport("advapi32.dll")]
        private static extern int LsaNtStatusToWinError(uint status);

        private const uint PolicyGetPrivateInformation = 0x00000004;
        private const uint PolicyCreateSecret          = 0x00000020;
        private const uint StatusObjectNameNotFound    = 0xC0000034;

        private static LSA_UNICODE_STRING ToLsaString(string value, out IntPtr memory)
        {
            memory = Marshal.StringToHGlobalUni(value);
            LSA_UNICODE_STRING result = new LSA_UNICODE_STRING();
            result.Buffer = memory;
            result.Length = (ushort)(value.Length * 2);
            result.MaximumLength = (ushort)(value.Length * 2 + 2);
            return result;
        }

        private static IntPtr OpenPolicy(uint access)
        {
            LSA_OBJECT_ATTRIBUTES attributes = new LSA_OBJECT_ATTRIBUTES();
            attributes.Length = Marshal.SizeOf(attributes);
            IntPtr handle;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, access, out handle);
            if (status != 0)
            {
                throw new Win32Exception(LsaNtStatusToWinError(status));
            }
            return handle;
        }

        // Grava o segredo. Com value = null, apaga (não falha se ele não existir).
        public static void Set(string key, string value)
        {
            IntPtr policy = OpenPolicy(PolicyCreateSecret);
            IntPtr keyMemory = IntPtr.Zero;
            IntPtr valueMemory = IntPtr.Zero;
            IntPtr valueStruct = IntPtr.Zero;
            try
            {
                LSA_UNICODE_STRING keyName = ToLsaString(key, out keyMemory);
                uint status;
                if (value == null)
                {
                    status = LsaStorePrivateData(policy, ref keyName, IntPtr.Zero);
                    if (status == StatusObjectNameNotFound)
                    {
                        status = 0;
                    }
                }
                else
                {
                    LSA_UNICODE_STRING data = ToLsaString(value, out valueMemory);
                    valueStruct = Marshal.AllocHGlobal(Marshal.SizeOf(data));
                    Marshal.StructureToPtr(data, valueStruct, false);
                    status = LsaStorePrivateData(policy, ref keyName, valueStruct);
                }
                if (status != 0)
                {
                    throw new Win32Exception(LsaNtStatusToWinError(status));
                }
            }
            finally
            {
                if (keyMemory != IntPtr.Zero) { Marshal.FreeHGlobal(keyMemory); }
                if (valueMemory != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(valueMemory); }
                if (valueStruct != IntPtr.Zero) { Marshal.FreeHGlobal(valueStruct); }
                LsaClose(policy);
            }
        }

        // Lê o segredo. Retorna null se ele não existir.
        public static string Get(string key)
        {
            IntPtr policy = OpenPolicy(PolicyGetPrivateInformation);
            IntPtr keyMemory = IntPtr.Zero;
            IntPtr data = IntPtr.Zero;
            try
            {
                LSA_UNICODE_STRING keyName = ToLsaString(key, out keyMemory);
                uint status = LsaRetrievePrivateData(policy, ref keyName, out data);
                if (status == StatusObjectNameNotFound)
                {
                    return null;
                }
                if (status != 0)
                {
                    throw new Win32Exception(LsaNtStatusToWinError(status));
                }
                LSA_UNICODE_STRING value = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
                return Marshal.PtrToStringUni(value.Buffer, value.Length / 2);
            }
            finally
            {
                if (keyMemory != IntPtr.Zero) { Marshal.FreeHGlobal(keyMemory); }
                if (data != IntPtr.Zero) { LsaFreeMemory(data); }
                LsaClose(policy);
            }
        }
    }

    // Confere se a senha é válida para uma conta local, sem abrir sessão.
    public static class LocalCredential
    {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LogonUser(string userName, string domain, string password, int logonType, int logonProvider, out IntPtr token);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private const int Logon32LogonInteractive = 2;
        private const int Logon32ProviderDefault  = 0;

        public static bool Test(string userName, string password)
        {
            IntPtr token;
            bool isValid = LogonUser(userName, ".", password, Logon32LogonInteractive, Logon32ProviderDefault, out token);
            if (isValid)
            {
                CloseHandle(token);
            }
            return isValid;
        }
    }
}
'@
}

function Read-AutoLogonCredentialFile {
    # O arquivo contém a senha em Base64 (UTF-8). Base64 NÃO é criptografia: só evita a leitura de relance.
    param([Parameter(Mandatory)] [string] $Path)

    # Get-Content -Raw retorna $null para arquivo vazio.
    $rawContent = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $rawContent -or $rawContent.Trim() -eq '') {
        throw "O arquivo de login automático está vazio: $Path"
    }
    try {
        $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rawContent.Trim()))
    }
    catch {
        throw "O arquivo de login automático não contém um valor Base64 válido: $Path"
    }
    if ([string]::IsNullOrEmpty($password)) {
        throw "O arquivo de login automático está vazio: $Path"
    }
    return $password
}

function Test-AutoLogonCredential {
    # Indica se a senha do provisionamento já está guardada como segredo protegido.
    Add-AutoLogonNativeMethod
    return $null -ne [WorkstationProvisioning.LsaSecret]::Get($autoLogonSecretKey)
}

function Import-AutoLogonCredential {
    # Lê a senha do arquivo do pendrive, confirma que ela funciona e a guarda como segredo protegido.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $UserName
    )
    Add-AutoLogonNativeMethod
    $password = Read-AutoLogonCredentialFile -Path $Path
    if (-not [WorkstationProvisioning.LocalCredential]::Test($UserName, $password)) {
        throw "A senha do arquivo $Path não é válida para a conta $UserName."
    }
    [WorkstationProvisioning.LsaSecret]::Set($autoLogonSecretKey, $password)
}

function Remove-PlainTextAutoLogonPassword {
    # Remove a senha em texto puro que o Windows pode deixar no registro (Winlogon\DefaultPassword).
    # Retorna $true se havia senha para remover.
    $winlogon = Get-ItemProperty -Path $winlogonKey
    if ($null -eq $winlogon.PSObject.Properties['DefaultPassword']) {
        return $false
    }
    Remove-ItemProperty -Path $winlogonKey -Name 'DefaultPassword'
    return $true
}

function Enable-AutoLogon {
    # Configura o Windows para entrar sozinho na conta, uma única vez, no próximo boot.
    param([Parameter(Mandatory)] [string] $UserName)

    Add-AutoLogonNativeMethod
    $password = [WorkstationProvisioning.LsaSecret]::Get($autoLogonSecretKey)
    if ($null -eq $password) {
        throw 'A senha do login automático não está guardada nesta máquina.'
    }

    [WorkstationProvisioning.LsaSecret]::Set($winlogonSecretKey, $password)
    New-ItemProperty -Path $winlogonKey -Name 'AutoAdminLogon'    -Value '1'                -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonKey -Name 'DefaultUserName'   -Value $UserName          -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonKey -Name 'DefaultDomainName' -Value $env:COMPUTERNAME  -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonKey -Name 'AutoLogonCount'    -Value 1                  -PropertyType DWord  -Force | Out-Null
    [void] (Remove-PlainTextAutoLogonPassword)
}

function Disable-AutoLogon {
    # Desliga o login automático. Com -RemoveCredential, apaga também a senha guardada do provisionamento.
    param([switch] $RemoveCredential)

    Add-AutoLogonNativeMethod
    New-ItemProperty -Path $winlogonKey -Name 'AutoAdminLogon' -Value '0' -PropertyType String -Force | Out-Null
    $winlogon = Get-ItemProperty -Path $winlogonKey
    if ($null -ne $winlogon.PSObject.Properties['AutoLogonCount']) {
        Remove-ItemProperty -Path $winlogonKey -Name 'AutoLogonCount'
    }
    [void] (Remove-PlainTextAutoLogonPassword)
    [WorkstationProvisioning.LsaSecret]::Set($winlogonSecretKey, $null)

    if ($RemoveCredential) {
        [WorkstationProvisioning.LsaSecret]::Set($autoLogonSecretKey, $null)
    }
}
