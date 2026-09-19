using Microsoft.Win32;

namespace MusicPlayerWin.App.Services;

public static class FileAssociationService
{
    private const string ProgId = "MusicPlayerWin.AudioFile";
    public static bool IsRegistered()
    {
        try
        {
            using var prog = Registry.CurrentUser.OpenSubKey($@"Software\Classes\{ProgId}\shell\open\command");
            var expected = Environment.ProcessPath;
            var command = prog?.GetValue(null)?.ToString();
            return !string.IsNullOrWhiteSpace(expected) && command?.Contains(expected, StringComparison.OrdinalIgnoreCase) == true;
        }
        catch { return false; }
    }

    public static void EnsureRegistered()
    {
        try
        {
            using var prog = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ProgId}");
            if (prog is null) return;
            prog.SetValue(null, "MusicPlayerWin audio file");
            using var command = prog.CreateSubKey("shell\\open\\command");
            command?.SetValue(null, $"\"{Environment.ProcessPath}\" \"%1\"");
            foreach (var ext in new[] { ".flac", ".mp3", ".m4a", ".m4b", ".aac", ".wav", ".aiff", ".aif", ".ogg", ".oga", ".opus", ".wma", ".ape", ".wv", ".mpc", ".dsf", ".dff", ".tta", ".shn" })
            {
                using var key = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ext}");
                if (key is not null && string.IsNullOrWhiteSpace(key.GetValue(null)?.ToString())) key.SetValue(null, ProgId);
            }
        }
        catch { }
    }

    public static void RemoveRegistered()
    {
        try
        {
            foreach (var ext in new[] { ".flac", ".mp3", ".m4a", ".m4b", ".aac", ".wav", ".aiff", ".aif", ".ogg", ".oga", ".opus", ".wma", ".ape", ".wv", ".mpc", ".dsf", ".dff", ".tta", ".shn" })
            {
                using var key = Registry.CurrentUser.OpenSubKey($@"Software\Classes\{ext}", writable: true);
                if (string.Equals(key?.GetValue(null)?.ToString(), ProgId, StringComparison.OrdinalIgnoreCase)) key.DeleteValue(null, false);
            }
            Registry.CurrentUser.DeleteSubKeyTree($@"Software\Classes\{ProgId}", false);
        }
        catch { }
    }
}
