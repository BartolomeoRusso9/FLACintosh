using System.Text.Json;
using MusicPlayerWin.Core.Infrastructure;

namespace MusicPlayerWin.Core.Offline;

public sealed record OfflineProgress(int Done, int Total);

public sealed class OfflineStore
{
    private sealed record SavedTrack(string Url, string Title, string Artist, string AlbumArtist, string Album, int? TrackNumber, int? DiscNumber, double? Duration);
    private sealed record SavedAlbum(string Id, string Title, string Artist, string? Year, string SourceKey, DateTimeOffset DownloadedAt, byte[]? Cover, IReadOnlyList<SavedTrack> Tracks);
    private sealed class Manifest
    {
        public Dictionary<string, string> Files { get; init; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, SavedAlbum> Albums { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    }

    private readonly object _gate = new();
    private readonly string _folder;
    private readonly string _manifestPath;
    private Manifest _manifest;
    private readonly Dictionary<string, OfflineProgress> _progress = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<LibraryAlbum> _queue = new();
    private Task? _worker;
    private string? _lastError;
    private long _size;

    public OfflineStore(string? applicationDataRoot = null)
    {
        var root = applicationDataRoot
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        _folder = Path.Combine(root, "Offline");
        Directory.CreateDirectory(_folder);
        _manifestPath = Path.Combine(_folder, "manifest.json");
        _manifest = LoadManifest();
        Measure();
    }

    public long SizeBytes { get { lock (_gate) return _size; } }
    public int DownloadedAlbumCount { get { lock (_gate) return _manifest.Albums.Count; } }
    public event EventHandler? Changed;
    public string? LastError { get { lock (_gate) return _lastError; } }
    public IReadOnlyDictionary<string, OfflineProgress> Progress { get { lock (_gate) return new Dictionary<string, OfflineProgress>(_progress); } }

    public bool IsDownloaded(LibraryAlbum album)
    {
        lock (_gate) return album.Tracks.Count > 0 && album.Tracks.All(t => _manifest.Files.ContainsKey(t.Key));
    }

    public bool IsDownloading(LibraryAlbum album)
    {
        lock (_gate) return _progress.ContainsKey(album.Id);
    }

    public Uri? LocalFile(Uri url)
    {
        lock (_gate)
        {
            if (!_manifest.Files.TryGetValue(LibraryTrack.KeyFor(url), out var file)) return null;
            var path = Path.Combine(_folder, file);
            return File.Exists(path) ? new Uri(path) : null;
        }
    }

    public IReadOnlyList<LibraryAlbum> Albums
    {
        get
        {
            lock (_gate)
            {
                return _manifest.Albums.Values.Select(ToAlbum).OrderBy(x => x.Title, StringComparer.OrdinalIgnoreCase).ToArray();
            }
        }
    }

    public void Download(LibraryAlbum album)
    {
        if (album.Source.IsFolder || album.Tracks.Count == 0) return;
        lock (_gate)
        {
            if (_progress.ContainsKey(album.Id)) return;
            _lastError = null;
            _progress[album.Id] = new OfflineProgress(0, album.Tracks.Count);
            _queue.Enqueue(album);
            StartWorkerLocked();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Cancel(LibraryAlbum album)
    {
        lock (_gate)
        {
            _progress.Remove(album.Id);
            // Queue removal is intentionally lazy; the worker checks progress again.
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Remove(LibraryAlbum album)
    {
        lock (_gate)
        {
            _progress.Remove(album.Id);
            var otherKeys = _manifest.Albums.Values
                .Where(x => x.Id != album.Id)
                .SelectMany(x => x.Tracks)
                .Select(t => Uri.TryCreate(t.Url, UriKind.Absolute, out var u) ? LibraryTrack.KeyFor(u) : null)
                .Where(x => x is not null)
                .Cast<string>()
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            foreach (var track in album.Tracks)
            {
                if (otherKeys.Contains(track.Key)) continue;
                if (_manifest.Files.TryGetValue(track.Key, out var file))
                {
                    TryDelete(Path.Combine(_folder, file));
                    _manifest.Files.Remove(track.Key);
                }
            }
            _manifest.Albums.Remove(album.Id);
            SaveLocked();
            MeasureLocked();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void RemoveAll()
    {
        lock (_gate)
        {
            _queue.Clear();
            _progress.Clear();
            _manifest = new Manifest();
            foreach (var file in Directory.EnumerateFiles(_folder))
                if (!string.Equals(file, _manifestPath, StringComparison.OrdinalIgnoreCase)) TryDelete(file);
            SaveLocked();
            MeasureLocked();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private void StartWorkerLocked()
    {
        if (_worker is { IsCompleted: false }) return;
        _worker = Task.Run(async () =>
        {
            while (true)
            {
                LibraryAlbum? album = null;
                lock (_gate)
                {
                    if (_queue.Count > 0) album = _queue.Dequeue();
                    else break;
                }
                await DownloadAlbumAsync(album).ConfigureAwait(false);
            }
        });
    }

    private async Task DownloadAlbumAsync(LibraryAlbum album)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        var failed = 0;

        foreach (var track in album.Tracks)
        {
            lock (_gate)
            {
                if (!_progress.ContainsKey(album.Id)) return;
            }

            try
            {
                if (LocalFile(track.Url) is null)
                {
                    using var response = await client.GetAsync(track.Url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
                    response.EnsureSuccessStatusCode();
                    var ext = Path.GetExtension(track.Url.AbsolutePath);
                    if (string.IsNullOrWhiteSpace(ext)) ext = "." + GuessExtension(response.Content.Headers.ContentType?.MediaType);
                    var name = RemoteCache.Fingerprint(track.Url) + ext.ToLowerInvariant();
                    var temp = Path.Combine(_folder, name + ".download");
                    var target = Path.Combine(_folder, name);
                    await using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    await using (var output = File.Create(temp))
                        await input.CopyToAsync(output).ConfigureAwait(false);
                    lock (_gate)
                    {
                        TryDelete(target);
                        File.Move(temp, target);
                        _manifest.Files[track.Key] = name;
                        SaveLocked();
                        MeasureLocked();
                    }
                }
            }
            catch (Exception ex)
            {
                failed++;
                lock (_gate) _lastError = ex.Message;
            }

            lock (_gate)
            {
                if (_progress.TryGetValue(album.Id, out var progress))
                    _progress[album.Id] = progress with { Done = Math.Min(progress.Total, progress.Done + 1) };
                    Changed?.Invoke(this, EventArgs.Empty);
            }
        }

        lock (_gate)
        {
            _manifest.Albums[album.Id] = new SavedAlbum(
                album.Id, album.Title, album.Artist, album.Year, album.Source.Key,
                DateTimeOffset.UtcNow, album.Cover,
                album.Tracks.Select(t => new SavedTrack(
                    LibraryTrack.Storable(t.Url), t.Title, t.Artist, t.AlbumArtist, t.Album,
                    t.TrackNumber, t.DiscNumber, t.Duration)).ToArray());
            if (failed > 0) _lastError = $"{failed} of {album.Tracks.Count} tracks of {album.Title} could not be downloaded.";
            _progress.Remove(album.Id);
            SaveLocked();
            MeasureLocked();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private LibraryAlbum ToAlbum(SavedAlbum album)
    {
        var source = LibrarySource.FromKey(album.SourceKey) ?? LibrarySource.Folder;
        var tracks = album.Tracks.Select(track => Uri.TryCreate(track.Url, UriKind.Absolute, out var url)
            ? new LibraryTrack
            {
                Id = url,
                Title = track.Title,
                Artist = track.Artist,
                AlbumArtist = track.AlbumArtist,
                Album = track.Album,
                TrackNumber = track.TrackNumber,
                DiscNumber = track.DiscNumber,
                Duration = track.Duration,
                HasLyrics = false,
                Source = source
            }
            : null).Where(x => x is not null).Cast<LibraryTrack>().ToArray();
        return new LibraryAlbum
        {
            Id = album.Id,
            Title = album.Title,
            Artist = album.Artist,
            Tracks = tracks,
            Cover = album.Cover,
            AddedAt = album.DownloadedAt,
            Year = album.Year,
            Source = source
        };
    }

    private Manifest LoadManifest()
    {
        try { return JsonSerializer.Deserialize<Manifest>(File.ReadAllText(_manifestPath)) ?? new Manifest(); }
        catch { return new Manifest(); }
    }

    private void SaveLocked() => AtomicFile.WriteAllText(_manifestPath, JsonSerializer.Serialize(_manifest, new JsonSerializerOptions { WriteIndented = true }));
    private void Measure() { lock (_gate) MeasureLocked(); }
    private void MeasureLocked() => _size = Directory.EnumerateFiles(_folder).Sum(path => new FileInfo(path).Length);
    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
    private static string GuessExtension(string? mediaType) => mediaType?.ToLowerInvariant() switch
    {
        "audio/flac" => "flac", "audio/mpeg" => "mp3", "audio/mp4" => "m4a", "audio/wav" => "wav",
        "audio/aac" => "aac", "audio/ogg" => "ogg", "audio/opus" => "opus", _ => "bin"
    };
}
