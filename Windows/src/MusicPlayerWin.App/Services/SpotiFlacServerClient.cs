using System.Net.WebSockets;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace MusicPlayerWin.App.Services;

public sealed record SpotiFlacResult(string Kind, string Title, string Subtitle, string? Album, string? Cover, string Link, double? Duration, string? Year);
public sealed record SpotiFlacTrack(int Index, string Title, string Artist, string Album, string? Cover, double? Duration, bool Explicit, string? ReleaseDate);
public sealed record SpotiFlacTracklist(string Link, string Title, string Artist, string? Cover, IReadOnlyList<SpotiFlacTrack> Tracks);

public sealed class SpotiFlacServerClient : IAsyncDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private ClientWebSocket? _socket;
    private Uri? _address;
    private string _token = "";
    private CancellationTokenSource? _receiveCts;
    public event Action<string>? Progress;
    public event EventHandler? DownloadFinished;

    public bool IsConfigured => _address is not null;

    public async Task ConfigureAsync(string address, string token, CancellationToken cancellationToken = default)
    {
        var normalized = address.Trim();
        if (!normalized.Contains("://", StringComparison.Ordinal)) normalized = "http://" + normalized;
        _address = new Uri(normalized.TrimEnd('/'));
        _token = token.Trim();
        await ConnectAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> PingAsync(CancellationToken cancellationToken = default)
    {
        try { await CallAsync("get_version", new { }, cancellationToken).ConfigureAwait(false); return true; }
        catch { return false; }
    }

    public async Task<IReadOnlyList<SpotiFlacResult>> SearchAsync(string query, CancellationToken cancellationToken = default)
    {
        var result = await CallAsync("search_provider", new { query, limit = 24 }, cancellationToken).ConfigureAwait(false);
        var output = new List<SpotiFlacResult>();
        if (result is null) return output;
        foreach (var group in new[] { ("tracks", "track"), ("albums", "album"), ("playlists", "playlist"), ("artists", "artist") })
        {
            if (!result.Value.TryGetProperty(group.Item1, out var rows) || rows.ValueKind != JsonValueKind.Array) continue;
            foreach (var row in rows.EnumerateArray())
            {
                var link = StringProp(row, "external_url");
                if (string.IsNullOrWhiteSpace(link)) continue;
                output.Add(new SpotiFlacResult(group.Item2, StringProp(row, "name") ?? StringProp(row, "title") ?? "Untitled", StringProp(row, "artist") ?? StringProp(row, "artists") ?? StringProp(row, "owner") ?? "", StringProp(row, "album"), StringProp(row, "cover") ?? StringProp(row, "images"), link, NumberProp(row, "duration_ms") is { } d ? d / 1000 : null, StringProp(row, "release_date")));
            }
        }
        return output;
    }

    public async Task<SpotiFlacTracklist> GetTracklistAsync(string link, CancellationToken cancellationToken = default)
    {
        await ConnectAsync(cancellationToken).ConfigureAwait(false);
        var tcs = new TaskCompletionSource<SpotiFlacTracklist>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handler = new Handler(tcs, link);
        _pendingTracklist = handler;
        _header = default;
        _ = await CallAsync("fetch_metadata", new { url = link }, cancellationToken).ConfigureAwait(false);
        try { return await tcs.Task.WaitAsync(TimeSpan.FromSeconds(120), cancellationToken).ConfigureAwait(false); }
        finally { if (ReferenceEquals(_pendingTracklist, handler)) _pendingTracklist = null; }
    }

    private Handler? _pendingTracklist;
    private sealed record Handler(TaskCompletionSource<SpotiFlacTracklist> Tcs, string Link) { public Action<JsonElement>? Metadata { get; init; } }
    private JsonElement _header;

    private void HandleMetadata(JsonElement value) => _header = value;

    public async Task DownloadAsync(string link, int[]? selectedIndices = null, CancellationToken cancellationToken = default)
    {
        var list = await GetTracklistAsync(link, cancellationToken).ConfigureAwait(false);
        var indices = selectedIndices ?? Enumerable.Range(0, list.Tracks.Count).ToArray();
        var settings = await CallAsync("load_settings", new { }, cancellationToken).ConfigureAwait(false);
        var config = settings is JsonElement element && element.ValueKind == JsonValueKind.Object
            ? JsonSerializer.Deserialize<Dictionary<string, object>>(element.GetRawText()) ?? new Dictionary<string, object>()
            : new Dictionary<string, object>();
        config.Remove("accent"); config.Remove("font"); config.Remove("theme"); config.Remove("preview_volume");
        await CallAsync("download_tracks", new { selected_indices = indices, config }, cancellationToken).ConfigureAwait(false);
    }

    private async Task ConnectAsync(CancellationToken cancellationToken)
    {
        if (_address is null) throw new InvalidOperationException("SpotiFLAC address is not configured.");
        if (_socket?.State == WebSocketState.Open) return;
        _socket?.Dispose();
        _socket = new ClientWebSocket();
        _socket.Options.SetRequestHeader("Cookie", $"spotiflac_web_token={_token}");
        var ws = new UriBuilder(_address) { Scheme = _address.Scheme == "https" ? "wss" : "ws", Path = (_address.AbsolutePath.TrimEnd('/') + "/ws") }.Uri;
        await _socket.ConnectAsync(ws, cancellationToken).ConfigureAwait(false);
        _receiveCts?.Cancel(); _receiveCts?.Dispose(); _receiveCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _ = ReceiveLoopAsync(_receiveCts.Token);
    }

    private async Task<JsonElement?> CallAsync(string method, object args, CancellationToken cancellationToken)
    {
        if (_address is null) throw new InvalidOperationException("SpotiFLAC address is not configured.");
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(_address, $"api/{method}"));
        request.Headers.Add("Cookie", $"spotiflac_web_token={_token}");
        request.Content = JsonContent.Create(args);
        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"SpotiFLAC returned {(int)response.StatusCode}.");
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false));
        return doc.RootElement.TryGetProperty("result", out var result) ? result.Clone() : null;
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        if (_socket is null) return;
        var buffer = new byte[64 * 1024];
        try
        {
            while (_socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await _socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    ms.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);
                using var doc = JsonDocument.Parse(ms.ToArray());
                var root = doc.RootElement;
                if (!root.TryGetProperty("fn", out var fn)) continue;
                var name = fn.GetString();
                if (name == "app_set_metadata" && root.TryGetProperty("args", out var a) && a.GetArrayLength() > 0) HandleMetadata(a[0]);
                else if (name == "showTracklist" && root.TryGetProperty("args", out var args) && args.GetArrayLength() > 0) ResolveTracklist(args[0]);
                else if (name == "app_set_progress") Progress?.Invoke(root.TryGetProperty("args", out var pa) && pa.ValueKind == JsonValueKind.Array && pa.GetArrayLength() > 0 ? pa[0].GetString() ?? "" : "");
                else if (name == "app_download_finished") DownloadFinished?.Invoke(this, EventArgs.Empty);
            }
        }
        catch { }
    }

    private void ResolveTracklist(JsonElement rows)
    {
        var handler = _pendingTracklist;
        if (handler is null) return;
        var header = _header;
        var tracks = new List<SpotiFlacTrack>();
        if (rows.ValueKind == JsonValueKind.Array)
        {
            var i = 0;
            foreach (var row in rows.EnumerateArray())
            {
                tracks.Add(new SpotiFlacTrack(IntProp(row, "index") ?? i, StringProp(row, "title") ?? "Untitled", StringProp(row, "artist") ?? "", StringProp(row, "album") ?? "", StringProp(row, "cover"), NumberProp(row, "duration_ms") is { } d ? d / 1000 : null, row.TryGetProperty("explicit", out var ex) && ex.ValueKind == JsonValueKind.True, StringProp(row, "release_date")));
                i++;
            }
        }
        handler.Tcs.TrySetResult(new SpotiFlacTracklist(handler.Link, StringProp(header, "title") ?? tracks.FirstOrDefault()?.Album ?? "", StringProp(header, "artist") ?? "", StringProp(header, "cover") ?? tracks.FirstOrDefault()?.Cover, tracks));
    }

    private static string? StringProp(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static double? NumberProp(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var value) && value.TryGetDouble(out var d) ? d : null;
    private static int? IntProp(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var value) && value.TryGetInt32(out var i) ? i : null;

    public async ValueTask DisposeAsync()
    {
        _receiveCts?.Cancel(); _receiveCts?.Dispose();
        _socket?.Dispose();
        _http.Dispose();
        await Task.CompletedTask;
    }
}
