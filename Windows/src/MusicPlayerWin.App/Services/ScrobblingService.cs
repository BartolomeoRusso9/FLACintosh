using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MusicPlayerWin.Core.History;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Services;

public sealed class ScrobblingService : IAsyncDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly ListeningHistoryStore _history;
    private readonly string _lastFmCredential = "MusicPlayerWin/LastFm";
    private readonly string _lastFmSecretCredential = "MusicPlayerWin/LastFmSecret";
    private readonly string _listenBrainzCredential = "MusicPlayerWin/ListenBrainz";
    private bool _lastFmEnabled;
    private bool _listenBrainzEnabled;
    private string _lastFmApiKey = "";
    private string _lastFmSecret = "";
    private string _lastFmSession = "";
    private string _listenBrainzToken = "";
    private string _listenBrainzServer = "https://api.listenbrainz.org";
    private string? _pendingLastFmToken;
    private readonly Queue<ListenRecord> _pending = new();
    private readonly string _queuePath;

    public ScrobblingService(ListeningHistoryStore history)
    {
        _history = history;
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(root);
        _queuePath = Path.Combine(root, "scrobble-queue.json");
        try
        {
            var saved = JsonSerializer.Deserialize<List<ListenRecord>>(File.ReadAllText(_queuePath));
            if (saved is not null) foreach (var item in saved) _pending.Enqueue(item);
        }
        catch { }
        _history.PlayRecorded += (_, record) =>
        {
            lock (_pending) { _pending.Enqueue(record); SaveQueueLocked(); }
            _ = FlushAsync();
        };
    }

    public void Configure(bool lastFmEnabled, string lastFmApiKey, string lastFmSecret, bool listenBrainzEnabled, string listenBrainzServer)
    {
        _lastFmEnabled = lastFmEnabled;
        _lastFmApiKey = lastFmApiKey.Trim();
        _lastFmSecret = WindowsCredentialStore.Read(_lastFmSecretCredential) ?? lastFmSecret.Trim();
        _lastFmSession = WindowsCredentialStore.Read(_lastFmCredential) ?? "";
        _listenBrainzEnabled = listenBrainzEnabled;
        _listenBrainzToken = WindowsCredentialStore.Read(_listenBrainzCredential) ?? "";
        _listenBrainzServer = (string.IsNullOrWhiteSpace(listenBrainzServer) ? "https://api.listenbrainz.org" : listenBrainzServer.TrimEnd('/'));
        _ = FlushAsync();
    }

    public bool HasLastFmSession => !string.IsNullOrWhiteSpace(_lastFmSession);
    public bool HasListenBrainzToken => !string.IsNullOrWhiteSpace(_listenBrainzToken);

    public void SaveLastFmSecret(string secret)
    {
        _lastFmSecret = secret.Trim();
        if (!string.IsNullOrWhiteSpace(_lastFmSecret)) WindowsCredentialStore.Save(_lastFmSecretCredential, "shared-secret", _lastFmSecret);
    }

    public void SaveLastFmSession(string sessionKey)
    {
        _lastFmSession = sessionKey.Trim();
        WindowsCredentialStore.Save(_lastFmCredential, "session", _lastFmSession);
    }
    public void SaveListenBrainzToken(string token) { _listenBrainzToken = token.Trim(); WindowsCredentialStore.Save(_listenBrainzCredential, "token", _listenBrainzToken); }
    public void RemoveLastFmSession() { _lastFmSession = ""; _pendingLastFmToken = null; WindowsCredentialStore.Remove(_lastFmCredential); }
    public void RemoveLastFmSecret() { _lastFmSecret = ""; WindowsCredentialStore.Remove(_lastFmSecretCredential); }
    public void RemoveListenBrainzToken()
    {
        _listenBrainzToken = "";
        WindowsCredentialStore.Remove(_listenBrainzCredential);
    }

    /// <summary>Starts the official Last.fm desktop auth flow: obtain a short-lived token, then authorize it in the browser.</summary>
    public async Task<Uri?> BeginLastFmAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_lastFmApiKey) || string.IsNullOrWhiteSpace(_lastFmSecret)) return null;
        var parameters = new Dictionary<string, string> { ["api_key"] = _lastFmApiKey, ["method"] = "auth.getToken" };
        parameters["api_sig"] = Sign(parameters);
        parameters["format"] = "json";
        using var response = await _http.GetAsync(BuildApiUri(parameters), cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false));
        var token = doc.RootElement.TryGetProperty("token", out var tokenElement) ? tokenElement.GetString() : null;
        if (string.IsNullOrWhiteSpace(token)) return null;
        _pendingLastFmToken = token;
        return new Uri($"https://www.last.fm/api/auth?api_key={Uri.EscapeDataString(_lastFmApiKey)}&token={Uri.EscapeDataString(token)}");
    }

    /// <summary>Completes the desktop flow after the user has granted access in the browser.</summary>
    public async Task<bool> CompleteLastFmAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_pendingLastFmToken) || string.IsNullOrWhiteSpace(_lastFmApiKey) || string.IsNullOrWhiteSpace(_lastFmSecret)) return false;
        var parameters = new Dictionary<string, string> { ["api_key"] = _lastFmApiKey, ["method"] = "auth.getSession", ["token"] = _pendingLastFmToken };
        parameters["api_sig"] = Sign(parameters);
        parameters["format"] = "json";
        using var response = await _http.GetAsync(BuildApiUri(parameters), cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) return false;
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false));
        if (!doc.RootElement.TryGetProperty("session", out var session) || !session.TryGetProperty("key", out var key)) return false;
        var sessionKey = key.GetString();
        if (string.IsNullOrWhiteSpace(sessionKey)) return false;
        SaveLastFmSession(sessionKey);
        _pendingLastFmToken = null;
        return true;
    }

    public async Task UpdateNowPlayingAsync(LibraryTrack? track, bool playing, CancellationToken cancellationToken = default)
    {
        if (!playing || track is null) return;
        if (_listenBrainzEnabled && !string.IsNullOrWhiteSpace(_listenBrainzToken))
            await SendListenBrainzAsync(track, "playing_now", null, cancellationToken).ConfigureAwait(false);
        if (_lastFmEnabled && HasLastFmCredentials)
            await LastFmCallAsync(new Dictionary<string, string>
            {
                ["method"] = "track.updateNowPlaying",
                ["artist"] = track.Artist,
                ["track"] = track.Title,
                ["album"] = track.Album,
                ["duration"] = track.Duration is > 0 ? Math.Round(track.Duration.Value).ToString(System.Globalization.CultureInfo.InvariantCulture) : ""
            }, cancellationToken).ConfigureAwait(false);
    }

    public async Task FlushAsync(CancellationToken cancellationToken = default)
    {
        if (!_listenBrainzEnabled && !_lastFmEnabled) return;
        while (true)
        {
            ListenRecord? item = null;
            lock (_pending) if (_pending.Count > 0) item = _pending.Peek();
            if (item is null) return;

            // Never drop a record while an enabled provider is not authorized yet.
            // This keeps history recoverable until both enabled backends can accept it.
            var lastFmReady = !_lastFmEnabled || HasLastFmCredentials;
            var listenBrainzReady = !_listenBrainzEnabled || !string.IsNullOrWhiteSpace(_listenBrainzToken);
            if (!lastFmReady || !listenBrainzReady) return;

            var ok = true;
            if (_listenBrainzEnabled)
                ok &= await SendListenBrainzAsync(item, cancellationToken).ConfigureAwait(false);
            if (_lastFmEnabled)
                ok &= await SendLastFmScrobbleAsync(item, cancellationToken).ConfigureAwait(false);
            if (!ok) return;
            lock (_pending) { if (_pending.Count > 0) _pending.Dequeue(); SaveQueueLocked(); }
        }
    }

    private bool HasLastFmCredentials => !string.IsNullOrWhiteSpace(_lastFmApiKey) && !string.IsNullOrWhiteSpace(_lastFmSecret) && !string.IsNullOrWhiteSpace(_lastFmSession);

    private async Task<bool> SendListenBrainzAsync(ListenRecord item, CancellationToken cancellationToken) =>
        await SendListenBrainzAsync(new LibraryTrack { Id = new Uri(item.TrackKey.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? item.TrackKey : "file:///"), Title = item.Title, Artist = item.Artist, AlbumArtist = item.Artist, Album = item.Album, HasLyrics = false }, "single", item, cancellationToken).ConfigureAwait(false);

    private async Task<bool> SendListenBrainzAsync(LibraryTrack track, string type, ListenRecord? record, CancellationToken cancellationToken)
    {
        var metadata = new Dictionary<string, object?>
        {
            ["artist_name"] = track.Artist,
            ["track_name"] = track.Title,
            ["release_name"] = track.Album,
            ["additional_info"] = new Dictionary<string, object?> { ["media_player"] = "MusicPlayerWin", ["submission_client"] = "MusicPlayerWin" }
        };
        if (track.Duration is > 0) ((Dictionary<string, object?>)metadata["additional_info"]!)["duration"] = (int)Math.Round(track.Duration.Value);
        var payload = new Dictionary<string, object?>
        {
            ["listen_type"] = type,
            ["payload"] = new[] { record is null ? new Dictionary<string, object?> { ["track_metadata"] = metadata } : new Dictionary<string, object?> { ["listened_at"] = record.StartedAt.ToUnixTimeSeconds(), ["track_metadata"] = metadata } }
        };
        return await PostJsonAsync($"{_listenBrainzServer}/1/submit-listens", payload, new Dictionary<string, string> { ["Authorization"] = $"Token {_listenBrainzToken}" }, cancellationToken).ConfigureAwait(false);
    }

    private async Task<bool> SendLastFmScrobbleAsync(ListenRecord item, CancellationToken cancellationToken)
    {
        var result = await LastFmCallAsync(new Dictionary<string, string>
        {
            ["method"] = "track.scrobble",
            ["artist"] = item.Artist,
            ["track"] = item.Title,
            ["album"] = item.Album,
            ["timestamp"] = item.StartedAt.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["duration"] = item.DurationSeconds > 0 ? Math.Round(item.DurationSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture) : ""
        }, cancellationToken).ConfigureAwait(false);
        return result;
    }

    private string Sign(IReadOnlyDictionary<string, string> parameters)
    {
        var canonical = string.Concat(parameters.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => x.Key + x.Value));
        return Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(canonical + _lastFmSecret))).ToLowerInvariant();
    }

    private static Uri BuildApiUri(IReadOnlyDictionary<string, string> parameters)
    {
        var query = string.Join("&", parameters.Select(x => $"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(x.Value)}"));
        return new Uri("https://ws.audioscrobbler.com/2.0/?" + query);
    }

    private async Task<bool> LastFmCallAsync(Dictionary<string, string> parameters, CancellationToken cancellationToken)
    {
        if (!HasLastFmCredentials) return false;
        parameters["api_key"] = _lastFmApiKey;
        parameters["sk"] = _lastFmSession;
        parameters["format"] = "json";
        parameters.Remove("api_sig");
        parameters.Remove("format");
        parameters["api_sig"] = Sign(parameters);
        parameters["format"] = "json";
        using var content = new FormUrlEncodedContent(parameters);
        using var response = await _http.PostAsync("https://ws.audioscrobbler.com/2.0/", content, cancellationToken).ConfigureAwait(false);
        return response.IsSuccessStatusCode;
    }

    private async Task<bool> PostJsonAsync(string url, object body, IDictionary<string, string> headers, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = JsonContent.Create(body) };
        foreach (var header in headers) request.Headers.TryAddWithoutValidation(header.Key, header.Value);
        try
        {
            using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            return response.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    private void SaveQueueLocked()
    {
        try { MusicPlayerWin.Core.Infrastructure.AtomicFile.WriteAllText(_queuePath, JsonSerializer.Serialize(_pending.ToArray())); } catch { }
    }

    public ValueTask DisposeAsync() { _http.Dispose(); return ValueTask.CompletedTask; }
}
