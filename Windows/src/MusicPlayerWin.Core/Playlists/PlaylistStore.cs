using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Offline;
using System.Text.Json;
using MusicPlayerWin.Core.Servers;
using MusicPlayerWin.Core.Infrastructure;

namespace MusicPlayerWin.Core.Playlists;

public sealed record PlaylistEntry(
    string Url,
    string Title,
    string Artist,
    string Album,
    double? Duration);

public sealed record Playlist(
    Guid Id,
    string Name,
    IReadOnlyList<PlaylistEntry> Entries,
    DateTimeOffset Created,
    DateTimeOffset Modified);

public sealed class PlaylistStore
{
    private readonly object _gate = new();
    private readonly string _filePath;
    private readonly List<Playlist> _playlists;

    public PlaylistStore(string? applicationDataRoot = null)
    {
        var root = applicationDataRoot
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(root);
        _filePath = Path.Combine(root, "playlists.json");
        _playlists = Load();
    }

    public IReadOnlyList<Playlist> Playlists
    {
        get { lock (_gate) return _playlists.ToArray(); }
    }

    public Playlist Create(string? name = null, IEnumerable<LibraryTrack>? tracks = null)
    {
        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            var playlist = new Playlist(Guid.NewGuid(), name ?? NextNameLocked(),
                (tracks ?? []).Select(ToEntry).ToArray(), now, now);
            _playlists.Add(playlist);
            SaveLocked();
            return playlist;
        }
    }

    public void Rename(Guid id, string name)
    {
        var value = name.Trim();
        if (value.Length == 0) return;
        Update(id, p => p with { Name = value });
    }

    public void Delete(Guid id)
    {
        lock (_gate)
        {
            _playlists.RemoveAll(x => x.Id == id);
            SaveLocked();
        }
    }

    public void Add(Guid id, IEnumerable<LibraryTrack> tracks) => Update(id, p =>
        p with { Entries = p.Entries.Concat(tracks.Select(ToEntry)).ToArray() });

    public void RemoveAt(Guid id, IEnumerable<int> indices)
    {
        var set = indices.ToHashSet();
        Update(id, p => p with { Entries = p.Entries.Where((_, i) => !set.Contains(i)).ToArray() });
    }

    public void Move(Guid id, int oldIndex, int newIndex)
    {
        Update(id, p =>
        {
            var items = p.Entries.ToList();
            if (oldIndex < 0 || oldIndex >= items.Count || newIndex < 0 || newIndex >= items.Count) return p;
            var item = items[oldIndex];
            items.RemoveAt(oldIndex);
            items.Insert(newIndex, item);
            return p with { Entries = items.ToArray() };
        });
    }

    public void Clear(Guid id) => Update(id, p => p with { Entries = Array.Empty<PlaylistEntry>() });

    public void Replace(Guid id, IEnumerable<LibraryTrack> tracks) => Update(id, p => p with { Entries = tracks.Select(ToEntry).ToArray() });

    public Playlist CreateFromQueue(string? name, IEnumerable<LibraryTrack> tracks) => Create(name, tracks);

    public Playlist? Find(Guid id)
    {
        lock (_gate) return _playlists.FirstOrDefault(x => x.Id == id);
    }

    public IReadOnlyList<LibraryTrack?> Resolve(Playlist playlist, LibraryStore library, OfflineStore? offline = null)
    {
        return playlist.Entries.Select(entry =>
        {
            if (!Uri.TryCreate(entry.Url, UriKind.Absolute, out var url)) return null;
            if (library.Find(url) is { } found) return found;

            if (url.IsFile && File.Exists(url.LocalPath))
                return Placeholder(url, entry);
            if (!url.IsFile && offline?.LocalFile(url) is not null)
                return Placeholder(url, entry);

            return library.Tracks.FirstOrDefault(t =>
                string.Equals(t.Title, entry.Title, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(t.Artist, entry.Artist, StringComparison.OrdinalIgnoreCase));
        }).ToArray();
    }

    private static PlaylistEntry ToEntry(LibraryTrack t) => new(LibraryTrack.Storable(t.Url), t.Title, t.Artist, t.Album, t.Duration);

    private static LibraryTrack Placeholder(Uri url, PlaylistEntry? entry = null) => new()
    {
        Id = url,
        Title = entry?.Title ?? Path.GetFileNameWithoutExtension(url.LocalPath),
        Artist = entry?.Artist ?? "Unknown Artist",
        AlbumArtist = entry?.Artist ?? "Unknown Artist",
        Album = entry?.Album ?? "Unknown Album",
        Duration = entry?.Duration,
        HasLyrics = false
    };

    private void Update(Guid id, Func<Playlist, Playlist> change)
    {
        lock (_gate)
        {
            var index = _playlists.FindIndex(x => x.Id == id);
            if (index < 0) return;
            _playlists[index] = change(_playlists[index]) with { Modified = DateTimeOffset.UtcNow };
            SaveLocked();
        }
    }

    private string NextNameLocked()
    {
        var names = _playlists.Select(x => x.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!names.Contains("New Playlist")) return "New Playlist";
        var n = 2;
        while (names.Contains($"New Playlist {n}")) n++;
        return $"New Playlist {n}";
    }

    private List<Playlist> Load()
    {
        try
        {
            var json = File.ReadAllText(_filePath);
            return JsonSerializer.Deserialize<List<Playlist>>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            }) ?? [];
        }
        catch { return []; }
    }

    private void SaveLocked()
    {
        var json = JsonSerializer.Serialize(_playlists, new JsonSerializerOptions { WriteIndented = true });
        AtomicFile.WriteAllText(_filePath, json);
    }
}
