using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.Core.Servers;

public sealed class SubsonicClient : IMusicServerClient
{
    private const string Version = "1.16.1";
    private const string Client = "MusicPlayerWin";
    private readonly MusicServer _server;
    private readonly string _password;
    private readonly HttpClient _http;

    public SubsonicClient(MusicServer server, string password, HttpClient? httpClient = null)
    {
        _server = server;
        _password = password;
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
    }

    public async Task<IReadOnlyList<LibraryAlbum>> AlbumsAsync(Action<int, int>? progress = null, CancellationToken cancellationToken = default)
    {
        var listed = new List<Album>();
        var offset = 0;
        while (true)
        {
            var page = await GetAsync<AlbumListResponse>("getAlbumList2", new Dictionary<string, string>
            {
                ["type"] = "alphabeticalByName", ["size"] = "500", ["offset"] = offset.ToString()
            }, cancellationToken).ConfigureAwait(false);
            var albums = page.Album ?? [];
            if (albums.Count == 0) break;
            listed.AddRange(albums);
            offset += albums.Count;
            if (albums.Count < 500) break;
        }

        progress?.Invoke(0, listed.Count);
        var found = new List<LibraryAlbum>(listed.Count);
        for (var i = 0; i < listed.Count; i++)
        {
            found.Add(await ReadAlbumAsync(listed[i], cancellationToken).ConfigureAwait(false));
            progress?.Invoke(i + 1, listed.Count);
        }
        return found;
    }

    public async Task<byte[]?> CoverAsync(string albumId, CancellationToken cancellationToken = default)
    {
        var url = Build("getCoverArt", new Dictionary<string, string> { ["id"] = albumId, ["size"] = "320" });
        using var response = await _http.GetAsync(url, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) return null;
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        return bytes.Length > 0 && bytes[0] != (byte)'{' ? bytes : null;
    }

    public Uri? StreamUri(string trackId) => Build("stream", new Dictionary<string, string> { ["id"] = trackId });

    public async Task<IReadOnlyList<ServerPlaylist>> PlaylistsAsync(CancellationToken cancellationToken = default)
    {
        var listed = await GetAsync<PlaylistListResponse>("getPlaylists", new Dictionary<string, string>(), cancellationToken).ConfigureAwait(false);
        var result = new List<ServerPlaylist>();
        foreach (var playlist in listed.Playlists ?? [])
        {
            var detail = await GetAsync<PlaylistWithSongsResponse>("getPlaylist", new Dictionary<string, string> { ["id"] = playlist.Id }, cancellationToken).ConfigureAwait(false);
            var urls = (detail.Entry ?? []).Select(x => StreamUri(x.Id)).Where(x => x is not null).Cast<Uri>().ToList();
            if (urls.Count > 0)
                result.Add(new ServerPlaylist($"{_server.Id:N}/{playlist.Id}", playlist.Name ?? "Playlist", urls, _server.Id) { ServerName = _server.Name });
        }
        return result;
    }

    public async Task PingAsync(CancellationToken cancellationToken = default)
    {
        _ = await GetAsync<EmptyResponse>("ping", new Dictionary<string, string>(), cancellationToken).ConfigureAwait(false);
    }

    private async Task<LibraryAlbum> ReadAlbumAsync(Album album, CancellationToken ct)
    {
        var detail = await GetAsync<AlbumWithSongsResponse>("getAlbum", new Dictionary<string, string> { ["id"] = album.Id }, ct).ConfigureAwait(false);
        var artist = album.Artist ?? "Unknown Artist";
        var art = Build("getCoverArt", new Dictionary<string, string> { ["id"] = album.CoverArt ?? album.Id, ["size"] = "600" });
        var tracks = (detail.Song ?? []).Select((song, index) => new LibraryTrack
        {
            Id = StreamUri(song.Id) ?? _server.Address,
            Title = song.Title ?? "Untitled",
            Artist = song.Artist ?? artist,
            AlbumArtist = artist,
            Album = album.Name ?? "Unknown Album",
            TrackNumber = song.Track ?? index + 1,
            DiscNumber = song.DiscNumber,
            Duration = song.Duration,
            HasLyrics = false,
            ArtworkUrl = art,
            Source = LibrarySource.Server(_server.Id)
        }).ToList();

        return new LibraryAlbum
        {
            Id = $"{_server.Id:N}|{album.Id}",
            Title = album.Name ?? "Unknown Album",
            Artist = artist,
            Tracks = tracks,
            Cover = await CoverAsync(album.CoverArt ?? album.Id, ct).ConfigureAwait(false),
            AddedAt = ServerDate.Parse(album.Created) ?? DateTimeOffset.MinValue,
            Year = album.Year?.ToString(),
            Source = LibrarySource.Server(_server.Id)
        };
    }

    private async Task<T> GetAsync<T>(string method, IReadOnlyDictionary<string, string> parameters, CancellationToken ct)
    {
        using var response = await _http.GetAsync(Build(method, parameters), ct).ConfigureAwait(false);
        var json = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) throw new MusicServerException($"Subsonic {method} returned {(int)response.StatusCode}.");

        var envelope = JsonSerializer.Deserialize<Envelope>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                       ?? throw new MusicServerException($"Subsonic {method} returned no JSON.");
        if (envelope.Response.Error is { } error)
        {
            if (error.Code == 40) throw new MusicServerException("Subsonic rejected the credentials.");
            throw new MusicServerException(error.Message ?? $"Subsonic error {error.Code}.");
        }
        object? value = typeof(T) switch
        {
            _ when typeof(T) == typeof(AlbumListResponse) => envelope.Response.AlbumList2,
            _ when typeof(T) == typeof(AlbumWithSongsResponse) => envelope.Response.Album,
            _ when typeof(T) == typeof(PlaylistListResponse) => envelope.Response.Playlists,
            _ when typeof(T) == typeof(PlaylistWithSongsResponse) => envelope.Response.Playlist,
            _ when typeof(T) == typeof(EmptyResponse) => new EmptyResponse(),
            _ => null
        };
        return (T?)(value ?? throw new MusicServerException($"Subsonic {method} returned nothing usable."))!;
    }

    private Uri Build(string method, IReadOnlyDictionary<string, string> parameters)
    {
        var salt = RandomNumberGenerator.GetInt32(int.MaxValue).ToString("x8");
        var digest = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(_password + salt))).ToLowerInvariant();
        var baseAddress = new Uri(_server.Address.ToString().TrimEnd('/') + "/");
        var target = new Uri(baseAddress, $"rest/{method}");
        var query = new List<KeyValuePair<string, string>>
        {
            new("u", _server.Username), new("t", digest), new("s", salt), new("v", Version), new("c", Client), new("f", "json")
        };
        query.AddRange(parameters);
        return ServerUrl.WithQuery(target, query);
    }

    private sealed record Envelope
    {
        [System.Text.Json.Serialization.JsonPropertyName("subsonic-response")]
        public required Response Response { get; init; }
    }

    private sealed record Response
    {
        public ApiError? Error { get; init; }
        public AlbumListResponse? AlbumList2 { get; init; }
        public AlbumWithSongsResponse? Album { get; init; }
        public PlaylistListResponse? Playlists { get; init; }
        public PlaylistWithSongsResponse? Playlist { get; init; }
    }

    private sealed record ApiError { public int Code { get; init; } public string? Message { get; init; } }
    private sealed record AlbumListResponse { public List<Album>? Album { get; init; } }
    private sealed record AlbumWithSongsResponse { public List<Song>? Song { get; init; } }
    private sealed record PlaylistListResponse { public List<Playlist>? Playlists { get; init; } }
    private sealed record PlaylistWithSongsResponse { public List<Song>? Entry { get; init; } }
    private sealed record Album { public required string Id { get; init; } public string? Name { get; init; } public string? Artist { get; init; } public string? CoverArt { get; init; } public int? Year { get; init; } public string? Created { get; init; } }
    private sealed record Playlist { public required string Id { get; init; } public string? Name { get; init; } }
    private sealed record Song { public required string Id { get; init; } public string? Title { get; init; } public string? Artist { get; init; } public int? Track { get; init; } public int? DiscNumber { get; init; } public int? Duration { get; init; } }
    private sealed record EmptyResponse;
}

public sealed class MusicServerException : Exception
{
    public MusicServerException(string message) : base(message) { }
    public MusicServerException(string message, Exception inner) : base(message, inner) { }
}
