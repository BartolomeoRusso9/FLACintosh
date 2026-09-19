namespace MusicPlayerWin.Core.Library;

/// <summary>Thread-safe in-memory library index shared by UI, scanner and watcher.</summary>
public sealed class LibraryStore
{
    private readonly object _gate = new();
    private readonly List<LibraryTrack> _tracks = [];
    private readonly Dictionary<string, byte[]> _covers = new(StringComparer.Ordinal);
    private string? _root;
    private readonly HashSet<string> _hiddenSources = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _hiddenSourcesPath;

    public LibraryStore()
    {
        var dataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(dataRoot);
        _hiddenSourcesPath = Path.Combine(dataRoot, "hidden-sources.json");
        LoadHiddenSources();
    }

    public IReadOnlyList<LibraryTrack> Tracks { get { lock (_gate) return _tracks.Where(t => !_hiddenSources.Contains(t.Source.Key)).ToArray(); } }
    public IReadOnlyList<LibraryAlbum> Albums
    {
        get
        {
            lock (_gate)
            {
                var tracks = _tracks.Where(t => !_hiddenSources.Contains(t.Source.Key)).ToArray();
                return LibraryScanner.Group(tracks, new Dictionary<string, byte[]>(_covers));
            }
        }
    }
    public IReadOnlyList<LibraryArtist> Artists =>
        Albums.GroupBy(a => a.Artist, StringComparer.OrdinalIgnoreCase)
            .Select(g => new LibraryArtist
            {
                Name = g.First().Artist,
                Albums = g.OrderBy(a => a.Title, StringComparer.OrdinalIgnoreCase).ToArray()
            })
            .OrderBy(a => a.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    public IReadOnlyList<LibraryTrack> Songs => Tracks.OrderBy(t => t.Title, StringComparer.OrdinalIgnoreCase).ToArray();
    public IReadOnlyList<LibraryAlbum> RecentlyAdded => Albums.OrderByDescending(a => a.AddedAt).ToArray();
    public int Count { get { lock (_gate) return _tracks.Count(t => !_hiddenSources.Contains(t.Source.Key)); } }
    public string? RootPath { get { lock (_gate) return _root; } }

    public IReadOnlyList<LibrarySource> Sources
    {
        get
        {
            lock (_gate)
            {
                return new[] { LibrarySource.Folder }
                    .Concat(_tracks.Select(t => t.Source).Where(s => !s.IsFolder).Distinct())
                    .ToArray();
            }
        }
    }

    public bool IsHidden(LibrarySource source)
    {
        lock (_gate) return _hiddenSources.Contains(source.Key);
    }

    public void SetHidden(LibrarySource source, bool hidden)
    {
        lock (_gate)
        {
            if (hidden) _hiddenSources.Add(source.Key);
            else _hiddenSources.Remove(source.Key);
            SaveHiddenSourcesLocked();
        }
    }

    public string SourceName(LibrarySource source) => source.IsFolder ? "Local Music" : $"Server {source.ServerId}";

    public void Clear()
    {
        lock (_gate) { _tracks.Clear(); _covers.Clear(); }
    }

    public void SetRoot(string? root) { lock (_gate) _root = string.IsNullOrWhiteSpace(root) ? null : Path.GetFullPath(root); }

    public void Replace(IEnumerable<LibraryTrack> tracks, IReadOnlyDictionary<string, byte[]>? covers = null)
    {
        lock (_gate)
        {
            _tracks.Clear();
            _covers.Clear();
            AddBatchLocked(tracks, covers);
        }
    }

    public void Add(LibraryTrack track) => AddBatch([track]);

    public void AddBatch(IEnumerable<LibraryTrack> tracks, IReadOnlyDictionary<string, byte[]>? covers = null)
    {
        lock (_gate) AddBatchLocked(tracks, covers);
    }

    private void AddBatchLocked(IEnumerable<LibraryTrack> tracks, IReadOnlyDictionary<string, byte[]>? covers)
    {
        foreach (var track in tracks)
        {
            var index = _tracks.FindIndex(t => string.Equals(t.Key, track.Key, StringComparison.OrdinalIgnoreCase));
            if (index >= 0) _tracks[index] = track; else _tracks.Add(track);
        }
        if (covers is not null)
            foreach (var pair in covers) _covers[pair.Key] = pair.Value;
    }

    public void AddAlbums(IEnumerable<LibraryAlbum> albums)
    {
        lock (_gate)
        {
            foreach (var album in albums)
            {
                AddBatchLocked(album.Tracks, album.Cover is { Length: > 0 }
                    ? new Dictionary<string, byte[]> { [LibraryScanner.AlbumId(album.Artist, album.Title)] = album.Cover }
                    : null);
            }
        }
    }

    public bool Remove(Uri uri)
    {
        var key = LibraryTrack.KeyFor(uri);
        lock (_gate)
        {
            var removed = _tracks.RemoveAll(t => string.Equals(t.Key, key, StringComparison.OrdinalIgnoreCase)) > 0;
            if (removed) RemoveUnusedCoversLocked();
            return removed;
        }
    }

    public int RemoveMissingUnderRoot()
    {
        lock (_gate)
        {
            if (string.IsNullOrWhiteSpace(_root)) return 0;
            var removed = _tracks.RemoveAll(t => t.Id.IsFile && !File.Exists(t.Id.LocalPath) && IsUnderRoot(t.Id.LocalPath, _root));
            if (removed > 0) RemoveUnusedCoversLocked();
            return removed;
        }
    }

    public bool Contains(Uri uri) => Find(uri) is not null;

    public LibraryTrack? Find(Uri uri)
    {
        var key = LibraryTrack.KeyFor(uri);
        lock (_gate) return _tracks.FirstOrDefault(t => string.Equals(t.Key, key, StringComparison.OrdinalIgnoreCase));
    }

    public LibraryTrack? FindEquivalent(Uri uri, Guid? serverId = null)
    {
        lock (_gate)
        {
            var key = LibraryTrack.KeyFor(uri);
            var exact = _tracks.FirstOrDefault(t => string.Equals(t.Key, key, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact;
            var requestedId = QueryValue(uri, "id");
            return _tracks.FirstOrDefault(track =>
                (!serverId.HasValue || track.Source.ServerId == serverId) && EquivalentRemoteId(track.Url, uri, requestedId));
        }
    }

    public IReadOnlyList<LibraryTrack> SearchTracks(string query, int limit = 100)
    {
        var terms = Tokenize(query);
        if (terms.Length == 0) return Array.Empty<LibraryTrack>();
        return Tracks.Select(t => (Track: t, Score: Score(t.Title, t.Artist, t.Album, terms)))
            .Where(x => x.Score > 0).OrderByDescending(x => x.Score).ThenBy(x => x.Track.Title, StringComparer.OrdinalIgnoreCase)
            .Take(Math.Clamp(limit, 1, 500)).Select(x => x.Track).ToArray();
    }

    public IReadOnlyList<LibraryAlbum> SearchAlbums(string query, int limit = 100)
    {
        var terms = Tokenize(query);
        if (terms.Length == 0) return Array.Empty<LibraryAlbum>();
        return Albums.Select(a => (Album: a, Score: Score(a.Title, a.Artist, a.Year ?? string.Empty, terms)))
            .Where(x => x.Score > 0).OrderByDescending(x => x.Score).ThenBy(x => x.Album.Title, StringComparer.OrdinalIgnoreCase)
            .Take(Math.Clamp(limit, 1, 500)).Select(x => x.Album).ToArray();
    }

    public IReadOnlyList<LibraryArtist> SearchArtists(string query, int limit = 100)
    {
        var terms = Tokenize(query);
        if (terms.Length == 0) return Array.Empty<LibraryArtist>();
        return Artists.Select(a => (Artist: a, Score: Score(a.Name, string.Empty, string.Empty, terms)))
            .Where(x => x.Score > 0).OrderByDescending(x => x.Score).ThenBy(x => x.Artist.Name, StringComparer.OrdinalIgnoreCase)
            .Take(Math.Clamp(limit, 1, 500)).Select(x => x.Artist).ToArray();
    }

    public LibraryAlbum? FindAlbum(string id) => Albums.FirstOrDefault(a => string.Equals(a.Id, id, StringComparison.Ordinal));
    public LibraryArtist? FindArtist(string name) => Artists.FirstOrDefault(a => string.Equals(a.Name, name, StringComparison.OrdinalIgnoreCase));

    public IReadOnlyList<LibraryTrack> InOrder() => Tracks.OrderBy(t => t.AlbumArtist, StringComparer.OrdinalIgnoreCase).ThenBy(t => t.Album, StringComparer.OrdinalIgnoreCase)
        .ThenBy(t => t.DiscNumber ?? 1).ThenBy(t => t.TrackNumber ?? int.MaxValue).ThenBy(t => t.Title, StringComparer.OrdinalIgnoreCase).ToArray();

    private void LoadHiddenSources()
    {
        try
        {
            if (!File.Exists(_hiddenSourcesPath)) return;
            var saved = System.Text.Json.JsonSerializer.Deserialize<string[]>(File.ReadAllText(_hiddenSourcesPath));
            if (saved is not null) foreach (var key in saved) _hiddenSources.Add(key);
        }
        catch { }
    }

    private void SaveHiddenSourcesLocked()
    {
        try
        {
            var json = System.Text.Json.JsonSerializer.Serialize(_hiddenSources.OrderBy(x => x).ToArray());
            Infrastructure.AtomicFile.WriteAllText(_hiddenSourcesPath, json);
        }
        catch { }
    }

    private static bool IsUnderRoot(string file, string root)
    {
        var full = Path.GetFullPath(file).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return full.StartsWith(basePath, StringComparison.OrdinalIgnoreCase);
    }

    private void RemoveUnusedCoversLocked()
    {
        var used = _tracks.GroupBy(t => LibraryScanner.AlbumId(t.AlbumArtist, t.Album)).Select(g => g.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var key in _covers.Keys.ToArray()) if (!used.Contains(key)) _covers.Remove(key);
    }

    private static int Score(string title, string artist, string album, string[] terms)
    {
        var score = 0;
        var fields = new[] { title, artist, album };
        foreach (var term in terms)
        {
            var best = fields.Max(field =>
            {
                var value = field.Trim();
                if (value.Equals(term, StringComparison.OrdinalIgnoreCase)) return 100;
                if (value.StartsWith(term, StringComparison.OrdinalIgnoreCase)) return 50;
                if (value.Contains(term, StringComparison.OrdinalIgnoreCase)) return 10;
                return 0;
            });
            if (best == 0) return 0;
            score += best;
        }
        return score;
    }

    private static string[] Tokenize(string query) => query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static bool EquivalentRemoteId(Uri left, Uri right, string? requestedId)
    {
        if (left.IsFile || right.IsFile) return false;
        if (!string.Equals(left.Scheme, right.Scheme, StringComparison.OrdinalIgnoreCase) || !string.Equals(left.Host, right.Host, StringComparison.OrdinalIgnoreCase) || left.Port != right.Port || !string.Equals(left.AbsolutePath, right.AbsolutePath, StringComparison.OrdinalIgnoreCase)) return false;
        return string.IsNullOrWhiteSpace(requestedId) || string.Equals(QueryValue(left, "id"), requestedId, StringComparison.OrdinalIgnoreCase);
    }

    private static string? QueryValue(Uri uri, string name)
    {
        foreach (var pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            if (parts.Length == 2 && string.Equals(Uri.UnescapeDataString(parts[0]), name, StringComparison.OrdinalIgnoreCase)) return Uri.UnescapeDataString(parts[1]);
        }
        return null;
    }
}
