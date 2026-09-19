using System.Net.Http.Json;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.Core.Servers;

public sealed class JellyfinClient : IMusicServerClient
{
    private readonly MusicServer _server;
    private readonly string _password;
    private readonly HttpClient _http;
    private readonly SemaphoreSlim _authGate = new(1, 1);
    private string? _token;
    private string? _userId;

    public JellyfinClient(MusicServer server, string password, HttpClient? httpClient = null)
    {
        _server = server;
        _password = password;
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
    }

    public async Task<IReadOnlyList<LibraryAlbum>> AlbumsAsync(Action<int, int>? progress = null, CancellationToken cancellationToken = default)
    {
        var user = await AuthenticateAsync(cancellationToken).ConfigureAwait(false);
        var response = await GetAsync<ItemsResponse>("Items", new Dictionary<string, string>
        {
            ["userId"] = user,
            ["IncludeItemTypes"] = "MusicAlbum",
            ["Recursive"] = "true",
            ["SortBy"] = "SortName",
            ["Fields"] = "DateCreated,ProductionYear,AlbumArtist",
            ["Limit"] = "5000"
        }, cancellationToken).ConfigureAwait(false);

        var items = response.Items ?? [];
        progress?.Invoke(0, items.Count);
        var result = new List<LibraryAlbum>(items.Count);
        for (var i = 0; i < items.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            result.Add(await ReadAlbumAsync(items[i], user, cancellationToken).ConfigureAwait(false));
            progress?.Invoke(i + 1, items.Count);
        }
        return result;
    }

    public async Task<byte[]?> CoverAsync(string albumId, CancellationToken cancellationToken = default)
    {
        var url = Build("Items/" + Uri.EscapeDataString(albumId) + "/Images/Primary", new Dictionary<string, string> { ["maxHeight"] = "320" });
        try
        {
            using var response = await _http.GetAsync(url, cancellationToken).ConfigureAwait(false);
            return response.StatusCode == HttpStatusCode.OK ? await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false) : null;
        }
        catch (HttpRequestException ex)
        {
            throw new MusicServerException("Could not reach Jellyfin.", ex);
        }
    }

    public Uri? StreamUri(string trackId)
    {
        if (string.IsNullOrWhiteSpace(_token)) return null;
        return Build($"Audio/{Uri.EscapeDataString(trackId)}/stream", new Dictionary<string, string>
        {
            ["static"] = "true",
            ["api_key"] = _token
        });
    }

    public async Task<IReadOnlyList<ServerPlaylist>> PlaylistsAsync(CancellationToken cancellationToken = default)
    {
        var user = await AuthenticateAsync(cancellationToken).ConfigureAwait(false);
        var listed = await GetAsync<ItemsResponse>("Items", new Dictionary<string, string>
        {
            ["userId"] = user,
            ["IncludeItemTypes"] = "Playlist",
            ["Recursive"] = "true",
            ["Fields"] = "MediaType"
        }, cancellationToken).ConfigureAwait(false);

        var result = new List<ServerPlaylist>();
        foreach (var playlist in listed.Items ?? [])
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (playlist.MediaType is not null && !string.Equals(playlist.MediaType, "Audio", StringComparison.OrdinalIgnoreCase))
                continue;

            var items = await GetAsync<ItemsResponse>($"Playlists/{Uri.EscapeDataString(playlist.Id)}/Items",
                new Dictionary<string, string> { ["userId"] = user }, cancellationToken).ConfigureAwait(false);

            var urls = (items.Items ?? []).Select(x => StreamUri(x.Id)).Where(x => x is not null).Cast<Uri>().ToList();
            if (urls.Count == 0) continue;
            result.Add(new ServerPlaylist($"{_server.Id:N}/{playlist.Id}", playlist.Name ?? "Playlist", urls, _server.Id) { ServerName = _server.Name });
        }
        return result;
    }

    public async Task PingAsync(CancellationToken cancellationToken = default)
    {
        _ = await AuthenticateAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<LibraryAlbum> ReadAlbumAsync(Item album, string user, CancellationToken ct)
    {
        var songs = await GetAsync<ItemsResponse>("Items", new Dictionary<string, string>
        {
            ["userId"] = user,
            ["ParentId"] = album.Id,
            ["IncludeItemTypes"] = "Audio",
            ["SortBy"] = "ParentIndexNumber,IndexNumber,SortName",
            ["Fields"] = "RunTimeTicks",
            ["Limit"] = "500"
        }, ct).ConfigureAwait(false);

        var artist = album.AlbumArtist ?? album.Name ?? "Unknown Artist";
        var trackList = (songs.Items ?? []).Select((song, index) => new LibraryTrack
        {
            Id = StreamUri(song.Id) ?? _server.Address,
            Title = song.Name ?? "Untitled",
            Artist = song.AlbumArtist ?? artist,
            AlbumArtist = artist,
            Album = album.Name ?? "Unknown Album",
            TrackNumber = song.IndexNumber ?? index + 1,
            DiscNumber = song.ParentIndexNumber,
            Duration = song.RunTimeTicks.HasValue ? song.RunTimeTicks.Value / 10_000_000d : null,
            HasLyrics = false,
            ArtworkUrl = Build($"Items/{Uri.EscapeDataString(album.Id)}/Images/Primary", new Dictionary<string, string> { ["maxHeight"] = "600" }),
            Source = LibrarySource.Server(_server.Id)
        }).ToList();

        return new LibraryAlbum
        {
            Id = $"{_server.Id:N}|{album.Id}",
            Title = album.Name ?? "Unknown Album",
            Artist = artist,
            Tracks = trackList,
            Cover = await CoverAsync(album.Id, ct).ConfigureAwait(false),
            AddedAt = ServerDate.Parse(album.DateCreated) ?? DateTimeOffset.MinValue,
            Year = album.ProductionYear?.ToString(),
            Source = LibrarySource.Server(_server.Id)
        };
    }

    private async Task<string> AuthenticateAsync(CancellationToken cancellationToken)
    {
        if (_userId is not null && _token is not null) return _userId;

        await _authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_userId is not null && _token is not null) return _userId;

            using var request = new HttpRequestMessage(HttpMethod.Post, Build("Users/AuthenticateByName", new Dictionary<string, string>()));
            request.Headers.TryAddWithoutValidation("Authorization", AuthorizationHeader());
            request.Content = new StringContent(JsonSerializer.Serialize(new { Username = _server.Username, Pw = _password }), Encoding.UTF8, "application/json");

            HttpResponseMessage response;
            try { response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false); }
            catch (HttpRequestException ex) { throw new MusicServerException("Could not reach Jellyfin.", ex); }

            if (response.StatusCode == HttpStatusCode.Unauthorized) throw new MusicServerException("Jellyfin rejected the credentials.");
            if (!response.IsSuccessStatusCode) throw new MusicServerException($"Jellyfin login returned {(int)response.StatusCode}.");

            var auth = await response.Content.ReadFromJsonAsync<AuthResponse>(cancellationToken: cancellationToken).ConfigureAwait(false)
                       ?? throw new MusicServerException("Jellyfin returned an empty login response.");
            _token = auth.AccessToken;
            _userId = auth.User.Id;
            return _userId;
        }
        finally
        {
            _authGate.Release();
        }
    }

    private async Task<T> GetAsync<T>(string path, IReadOnlyDictionary<string, string> query, CancellationToken ct)
    {
        var user = await AuthenticateAsync(ct).ConfigureAwait(false);
        _ = user;
        using var request = new HttpRequestMessage(HttpMethod.Get, Build(path, query));
        request.Headers.TryAddWithoutValidation("Authorization", AuthorizationHeader());
        HttpResponseMessage response;
        try { response = await _http.SendAsync(request, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new MusicServerException("Could not reach Jellyfin.", ex); }
        if (response.StatusCode == HttpStatusCode.Unauthorized) throw new MusicServerException("Jellyfin authentication expired.");
        if (!response.IsSuccessStatusCode) throw new MusicServerException($"Jellyfin {path} returned {(int)response.StatusCode}.");
        return await response.Content.ReadFromJsonAsync<T>(cancellationToken: ct).ConfigureAwait(false)
               ?? throw new MusicServerException($"Jellyfin {path} returned no usable JSON.");
    }

    private Uri Build(string path, IReadOnlyDictionary<string, string> query)
    {
        var baseAddress = new Uri(_server.Address.ToString().TrimEnd('/') + "/");
        var target = new Uri(baseAddress, path.TrimStart('/'));
        return ServerUrl.WithQuery(target, query);
    }

    private string AuthorizationHeader()
    {
        var header = $"MediaBrowser Client=\"MusicPlayerWin\", Device=\"Windows\", DeviceId=\"musicplayerwin\", Version=\"0.2\"";
        if (_token is not null) header += $", Token=\"{_token}\"";
        return header;
    }

    private sealed record AuthResponse(string AccessToken, AuthUser User);
    private sealed record AuthUser(string Id);
    private sealed record ItemsResponse(List<Item>? Items);
    private sealed record Item
    {
        public required string Id { get; init; }
        public string? Name { get; init; }
        public string? AlbumArtist { get; init; }
        public int? ProductionYear { get; init; }
        public string? DateCreated { get; init; }
        public int? IndexNumber { get; init; }
        public int? ParentIndexNumber { get; init; }
        public long? RunTimeTicks { get; init; }
        public string? MediaType { get; init; }
    }
}
