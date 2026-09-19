namespace MusicPlayerWin.Core.Library;

/// <summary>
/// Where a track lives: the library folder on this PC, or a server.
///
/// Every source is in the library at once, so the same record can be there
/// twice — ripped locally and served by Jellyfin. This is what tells them
/// apart on screen.
/// </summary>
public readonly record struct LibrarySource
{
    private enum Kind { Folder, Server }

    private readonly Kind _kind;
    private readonly Guid? _serverId;

    private LibrarySource(Kind kind, Guid? serverId)
    {
        _kind = kind;
        _serverId = serverId;
    }

    public static readonly LibrarySource Folder = new(Kind.Folder, null);

    public static LibrarySource Server(Guid id) => new(Kind.Server, id);

    public bool IsFolder => _kind == Kind.Folder;
    public Guid? ServerId => _serverId;

    /// <summary>A stable string, for remembering which sources are hidden.</summary>
    public string Key => _kind == Kind.Folder ? "folder" : _serverId!.Value.ToString();

    public static LibrarySource? FromKey(string key)
    {
        if (key == "folder") return Folder;
        return Guid.TryParse(key, out var id) ? Server(id) : null;
    }
}

/// <summary>
/// One playable file, as the library knows it.
///
/// Identified by its URL rather than by a tag: two different rips of the
/// same song are two rows, which is what the file system says and what a
/// person renaming a folder expects.
/// </summary>
public sealed record LibraryTrack
{
    public required Uri Id { get; init; }
    public required string Title { get; init; }
    public required string Artist { get; init; }
    public required string AlbumArtist { get; init; }
    public required string Album { get; init; }
    public int? TrackNumber { get; init; }
    public int? DiscNumber { get; init; }
    public double? Duration { get; init; }
    public string? Year { get; init; }

    /// <summary>
    /// Whether this track has timed lyrics to show — the whole point of the
    /// app, so the library says so up front rather than after you press play.
    /// </summary>
    public required bool HasLyrics { get; init; }

    /// <summary>
    /// Embedded lyrics, when the audio container exposes them. Local .lrc files
    /// remain the preferred sidecar source; this value is the fallback.
    /// </summary>
    public string? EmbeddedLyrics { get; init; }

    /// <summary>
    /// A server track's sleeve. A stream carries no tags to read one from, so
    /// the player asks the server for it instead; local files leave it null.
    /// </summary>
    public Uri? ArtworkUrl { get; init; }

    public LibrarySource Source { get; init; } = LibrarySource.Folder;

    public Uri Url => Id;

    /// <summary>
    /// What identifies the track across launches: the file's path, or for a
    /// server track its address without the credentials that change with
    /// every login or request.
    /// </summary>
    public string Key => KeyFor(Id);

    public static string KeyFor(Uri url) =>
        url.IsFile ? Path.GetFullPath(url.LocalPath) : RemoteCache.Fingerprint(url);

    /// <summary>
    /// The address as it may be written to disk: a server track's without the
    /// login it was built with — Jellyfin's <c>api_key</c>, Subsonic's token
    /// and salt. Its key is unchanged, so it still finds the track.
    /// </summary>
    public static string Storable(Uri url)
    {
        if (url.IsFile) return url.AbsoluteUri;

        // Manual query parse rather than System.Web.HttpUtility, to keep this
        // library free of any doubt about which reference assemblies a given
        // project style pulls in.
        string? id = null;
        foreach (var pair in url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            if (parts.Length == 2 && Uri.UnescapeDataString(parts[0]) == "id")
            {
                id = Uri.UnescapeDataString(parts[1]);
                break;
            }
        }

        var builder = new UriBuilder(url) { Query = id is not null ? $"id={Uri.EscapeDataString(id)}" : string.Empty };
        return builder.Uri.AbsoluteUri;
    }
}

/// <summary>Tracks grouped the way a record is.</summary>
public sealed record LibraryAlbum
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Artist { get; init; }
    public required IReadOnlyList<LibraryTrack> Tracks { get; init; }

    /// <summary>
    /// A small JPEG, made during the scan. The full-size cover stays in the
    /// file: a grid of two hundred 3000x3000 sleeves is a gigabyte of RAM.
    /// </summary>
    public byte[]? Cover { get; init; }

    /// <summary>
    /// Newest file in the album, which is what "recently added" means when
    /// the library is a folder rather than a service.
    /// </summary>
    public required DateTimeOffset AddedAt { get; init; }

    public string? Year { get; init; }
    public LibrarySource Source { get; init; } = LibrarySource.Folder;

    public int LyricCount => Tracks.Count(t => t.HasLyrics);
    public double Duration => Tracks.Sum(t => t.Duration ?? 0);
}

/// <summary>An artist and the records of theirs that are on disk.</summary>
public sealed record LibraryArtist
{
    public required string Name { get; init; }
    public required IReadOnlyList<LibraryAlbum> Albums { get; init; }

    public string Id => Name;
    public int TrackCount => Albums.Sum(a => a.Tracks.Count);
}
