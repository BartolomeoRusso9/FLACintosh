using System.Diagnostics;
using System.Text.Json;

namespace MusicPlayerWin.App.Services;

public sealed class SpotiFlacCliBridge
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(10) };
    public string? ExecutablePath { get; private set; }
    public string? Version { get; private set; }
    public string? LatestVersion { get; private set; }
    public bool UpdateAvailable => Version is not null && LatestVersion is not null && CompareVersions(LatestVersion, Version) > 0;

    public bool Detect()
    {
        var path = FindOnPath();
        if (path is null) { ExecutablePath = null; Version = null; return false; }
        ExecutablePath = path; Version = TryGetVersion(path); return true;
    }

    public async Task<string?> CheckLatestVersionAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var response = await _http.GetAsync("https://pypi.org/pypi/spotiflac/json", cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false));
            LatestVersion = doc.RootElement.TryGetProperty("info", out var info) && info.TryGetProperty("version", out var version) ? version.GetString() : null;
            return LatestVersion;
        }
        catch (Exception ex) { AppLog.Warn("Unable to check the latest SpotiFLAC version.", ex); return null; }
    }

    public Process? LaunchTui(string folder)
    {
        if (ExecutablePath is null && !Detect()) return null;
        var executable = ExecutablePath!;
        var safeFolder = folder.Replace("\"", "\\\"");
        var safeExe = executable.Replace("\"", "\\\"");
        var info = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            UseShellExecute = true,
            Arguments = $"/c start wt.exe cmd /k cd /d \"{safeFolder}\" ^&^& \"{safeExe}\" --tui"
        };
        return Process.Start(info);
    }

    private static int CompareVersions(string left, string right)
    {
        var a = left.TrimStart('v').Split('.', '-', '+');
        var b = right.TrimStart('v').Split('.', '-', '+');
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var av = i < a.Length && int.TryParse(a[i], out var an) ? an : 0;
            var bv = i < b.Length && int.TryParse(b[i], out var bn) ? bn : 0;
            if (av != bv) return av.CompareTo(bv);
        }
        return 0;
    }

    private static string? FindOnPath()
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var folder in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var name in new[] { "spotiflac.exe", "spotiflac.cmd", "spotiflac.bat" })
            {
                var candidate = Path.Combine(folder.Trim(), name);
                if (File.Exists(candidate)) return candidate;
            }
        return null;
    }

    private static string? TryGetVersion(string exe)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo { FileName = exe, Arguments = "--version", RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true });
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            return process.ExitCode == 0 ? output.Trim() : null;
        }
        catch { return null; }
    }

    public void Dispose() => _http.Dispose();
}
