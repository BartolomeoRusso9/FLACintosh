namespace MusicPlayerWin.App.Services;

public sealed class FirstRunService
{
    private readonly string _path;

    public FirstRunService(string? root = null)
    {
        root ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(root);
        _path = Path.Combine(root, "first-run-complete");
    }

    public bool IsFirstRun => !File.Exists(_path);

    public void MarkComplete() => File.WriteAllText(_path, DateTimeOffset.UtcNow.ToString("O"));
}
