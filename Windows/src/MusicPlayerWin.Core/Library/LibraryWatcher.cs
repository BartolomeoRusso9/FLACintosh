namespace MusicPlayerWin.Core.Library;

/// <summary>
/// Debounced filesystem watcher for a local music root. It never scans on the
/// FileSystemWatcher callback thread; consumers receive a coalesced path list.
/// </summary>
public sealed class LibraryWatcher : IDisposable
{
    private readonly object _gate = new();
    private readonly FileSystemWatcher _watcher;
    private readonly Timer _debounce;
    private readonly HashSet<string> _pending = new(StringComparer.OrdinalIgnoreCase);
    private bool _disposed;

    public LibraryWatcher(string root)
    {
        if (string.IsNullOrWhiteSpace(root)) throw new ArgumentException("A root is required.", nameof(root));
        _watcher = new FileSystemWatcher(Path.GetFullPath(root))
        {
            IncludeSubdirectories = true,
            Filter = "*",
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents = true
        };
        _watcher.Created += OnChanged;
        _watcher.Changed += OnChanged;
        _watcher.Deleted += OnChanged;
        _watcher.Renamed += OnRenamed;
        _debounce = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public event EventHandler<IReadOnlyList<string>>? Changed;

    private void OnChanged(object? sender, FileSystemEventArgs e) => Enqueue(e.FullPath);

    private void OnRenamed(object? sender, RenamedEventArgs e)
    {
        Enqueue(e.OldFullPath);
        Enqueue(e.FullPath);
    }

    private void Enqueue(string path)
    {
        if (_disposed) return;
        lock (_gate)
        {
            _pending.Add(Path.GetFullPath(path));
            _debounce.Change(800, Timeout.Infinite);
        }
    }

    private void Flush()
    {
        string[] paths;
        lock (_gate)
        {
            if (_pending.Count == 0) return;
            paths = _pending.ToArray();
            _pending.Clear();
        }
        Changed?.Invoke(this, paths);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _watcher.EnableRaisingEvents = false;
        _watcher.Created -= OnChanged;
        _watcher.Changed -= OnChanged;
        _watcher.Deleted -= OnChanged;
        _watcher.Renamed -= OnRenamed;
        _watcher.Dispose();
        lock (_gate) _pending.Clear();
        _debounce.Dispose();
    }
}
