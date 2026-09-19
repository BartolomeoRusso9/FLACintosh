using System.Text;

namespace MusicPlayerWin.App.Services;

public static class AppLog
{
    private static readonly object Gate = new();
    private static readonly string LogDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin", "logs");

    public static string LogPath
    {
        get { Directory.CreateDirectory(LogDirectory); return Path.Combine(LogDirectory, "app.log"); }
    }

    public static void Info(string message) => Write("INFO", message, null);
    public static void Warn(string message, Exception? exception = null) => Write("WARN", message, exception);
    public static void Error(string message, Exception? exception = null) => Write("ERROR", message, exception);

    private static void Write(string level, string message, Exception? exception)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(LogDirectory);
                var line = new StringBuilder()
                    .Append(DateTimeOffset.Now.ToString("O"))
                    .Append(' ').Append(level).Append(' ').Append(message);
                if (exception is not null) line.AppendLine().Append(exception);
                File.AppendAllText(LogPath, line.AppendLine().ToString());
            }
        }
        catch { }
    }
}

public sealed record ServiceHealth(string Name, bool Healthy, string Detail);
