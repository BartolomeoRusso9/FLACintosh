using Microsoft.Win32;

namespace MusicPlayerWin.App.Services;

public static class WindowsStartupService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "MusicPlayerWin";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, false);
            return key?.GetValue(ValueName) is string value && !string.IsNullOrWhiteSpace(value);
        }
        catch { return false; }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (key is null) return;
            if (!enabled) key.DeleteValue(ValueName, false);
            else
            {
                var exe = Environment.ProcessPath;
                if (!string.IsNullOrWhiteSpace(exe)) key.SetValue(ValueName, $"\"{exe}\"");
            }
        }
        catch (Exception ex) { AppLog.Warn("Could not update Windows startup registration.", ex); }
    }
}
