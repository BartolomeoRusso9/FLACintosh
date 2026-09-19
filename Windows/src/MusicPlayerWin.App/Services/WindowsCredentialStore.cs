using System.Runtime.InteropServices;
using System.Text;

namespace MusicPlayerWin.App.Services;

internal static class WindowsCredentialStore
{
    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;
    private const int ERROR_NOT_FOUND = 1168;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string? UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL userCredential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr buffer);

    public static void Save(string target, string username, string secret)
    {
        var bytes = Encoding.UTF8.GetBytes(secret);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = target,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                UserName = username
            };
            if (!CredWrite(ref credential, 0))
                throw new InvalidOperationException($"Windows Credential Manager failed to save the credential ({Marshal.GetLastWin32Error()}).");
        }
        finally { Marshal.FreeHGlobal(blob); }
    }

    public static string? Read(string target)
    {
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out var ptr)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize <= 0) return string.Empty;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally { CredFree(ptr); }
    }

    public static void Remove(string target)
    {
        if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return;
        var error = Marshal.GetLastWin32Error();
        if (error != ERROR_NOT_FOUND)
            throw new InvalidOperationException($"Windows Credential Manager failed to delete the credential ({error}).");
    }
}
