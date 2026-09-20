using System.Collections.ObjectModel;
using System.Net.WebSockets;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace MusicPlayerWin.App.Services;

public sealed record SpotiFlacResult(string Kind, string Title, string Subtitle, string? Album, string? Cover, string Link, double? Duration, string? Year);
public sealed record SpotiFlacTrack(int Index, string Title, string Artist, string Album, string? AlbumLink, string? Cover, double? Duration, bool Explicit, string? ReleaseDate);
public sealed record SpotiFlacTracklist(string Link, string Title, string Artist, string? Cover, string? ReleaseDate, string? Description, string? Owner, int? Followers, int? Listeners, IReadOnlyList<SpotiFlacTrack> Tracks);

public enum SpotiFlacDownloadState { Waiting, Preparing, Downloading, Finished, Failed, Unknown }

/// <summary>A queued or running download, tracked the way FLACintosh tracks one on macOS.</summary>
public sealed class SpotiFlacDownload(SpotiFlacResult item, int[]? indices)
{
    public Guid Id { get; } = Guid.NewGuid();
    public SpotiFlacResult Item { get; } = item;
    /// <summary>Positions in the item's track list; null for all of it.</summary>
    public int[]? Indices { get; } = indices;
    public SpotiFlacDownloadState State { get; set; } = SpotiFlacDownloadState.Waiting;
    public string? Progress { get; set; }
    public string? Error { get; set; }
    public int TrackCount { get; set; }
    public bool IsActive => State is SpotiFlacDownloadState.Waiting or SpotiFlacDownloadState.Preparing or SpotiFlacDownloadState.Downloading;
}

public sealed class SpotiFlacServerClient : IAsyncDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private ClientWebSocket? _socket;
    private Uri? _address;
    private string _token = "";
    private CancellationTokenSource? _receiveCts;
    private Task? _worker;
    public event Action<string>? Progress;
    public event EventHandler? DownloadFinished;
    public event EventHandler? DownloadsChanged;

    public ObservableCollection<SpotiFlacDownload> Downloads { get; } = [];

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

    // MARK: - Downloads (queued, sequential — the server has one working track list)

    public bool IsDownloading(SpotiFlacResult item) => Downloads.Any(d => d.Item.Link == item.Link && d.IsActive);

    /// <summary>Queues a download: everything at <paramref name="item"/>'s link, or only <paramref name="indices"/> of its list.</summary>
    public void Enqueue(SpotiFlacResult item, int[]? indices = null)
    {
        if (indices is { Length: 0 }) return;
        if (indices is null && IsDownloading(item)) return;
        Downloads.Insert(0, new SpotiFlacDownload(item, indices));
        DownloadsChanged?.Invoke(this, EventArgs.Empty);
        if (_worker is null || _worker.IsCompleted) _worker = RunQueueAsync();
    }

    private async Task RunQueueAsync()
    {
        while (Downloads.LastOrDefault(d => d.State == SpotiFlacDownloadState.Waiting) is { } next)
            await RunDownloadAsync(next).ConfigureAwait(false);
    }

    private async Task RunDownloadAsync(SpotiFlacDownload download)
    {
        download.State = SpotiFlacDownloadState.Preparing;
        DownloadsChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            var list = await GetTracklistAsync(download.Item.Link).ConfigureAwait(false);
            var indices = (download.Indices ?? Enumerable.Range(0, list.Tracks.Count).ToArray()).Where(i => i >= 0 && i < list.Tracks.Count).ToArray();
            if (indices.Length == 0) throw new InvalidOperationException("SpotiFLAC found no tracks at that link.");

            var settings = await CallAsync("load_settings", new { }, CancellationToken.None).ConfigureAwait(false);
            var config = settings is JsonElement element && element.ValueKind == JsonValueKind.Object
                ? JsonSerializer.Deserialize<Dictionary<string, object>>(element.GetRawText()) ?? new Dictionary<string, object>()
                : new Dictionary<string, object>();
            config.Remove("accent"); config.Remove("font"); config.Remove("theme"); config.Remove("preview_volume");

            download.State = SpotiFlacDownloadState.Downloading;
            ArmFinish();
            DownloadsChanged?.Invoke(this, EventArgs.Empty);
            await CallAsync("download_tracks", new { selected_indices = indices, config }, CancellationToken.None).ConfigureAwait(false);

            var outcome = await WaitForFinishAsync().ConfigureAwait(false);
            download.TrackCount = indices.Length;
            download.State = outcome switch
            {
                true => SpotiFlacDownloadState.Finished,
                false => SpotiFlacDownloadState.Failed,
                null => SpotiFlacDownloadState.Unknown
            };
            if (outcome == false) download.Error = "SpotiFLAC could not download every track — its log says which.";
            if (outcome is not null) DownloadFinished?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            CancelFinish();
            download.State = SpotiFlacDownloadState.Failed;
            download.Error = ex.Message;
        }
        DownloadsChanged?.Invoke(this, EventArgs.Empty);
    }

    // The end of a batch can arrive before anything is waiting for it, so the
    // outcome is caught from the moment the batch is sent and kept until asked for.
    private bool _finishArmed;
    private bool _finishHasOutcome;
    private bool? _finishOutcome;
    private TaskCompletionSource<bool?>? _finishWaiter;

    private void ArmFinish() { _finishArmed = true; _finishHasOutcome = false; }
    private void CancelFinish() { _finishArmed = false; _finishHasOutcome = false; }

    private Task<bool?> WaitForFinishAsync()
    {
        if (_finishHasOutcome)
        {
            var outcome = _finishOutcome;
            CancelFinish();
            return Task.FromResult(outcome);
        }
        var tcs = new TaskCompletionSource<bool?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _finishWaiter = tcs;
        return tcs.Task;
    }

    private void ResolveFinish(bool? outcome)
    {
        if (_finishWaiter is { } waiter)
        {
            _finishWaiter = null;
            CancelFinish();
            waiter.TrySetResult(outcome);
        }
        else if (_finishArmed)
        {
            _finishOutcome = outcome;
            _finishHasOutcome = true;
        }
    }

    private void UpdateActiveDownloadProgress(string label)
    {
        var active = Downloads.FirstOrDefault(d => d.State == SpotiFlacDownloadState.Downloading);
        if (active is null) return;
        active.Progress = string.IsNullOrEmpty(label) ? null : label;
        DownloadsChanged?.Invoke(this, EventArgs.Empty);
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
                    if (result.MessageType == WebSocketMessageType.Close) { ResolveFinish(null); return; }
                    ms.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);
                using var doc = JsonDocument.Parse(ms.ToArray());
                var root = doc.RootElement;
                if (!root.TryGetProperty("fn", out var fn)) continue;
                var name = fn.GetString();
                if (name == "app_set_metadata" && root.TryGetProperty("args", out var a) && a.GetArrayLength() > 0) HandleMetadata(a[0]);
                else if (name == "showTracklist" && root.TryGetProperty("args", out var args) && args.GetArrayLength() > 0) ResolveTracklist(args[0]);
                else if (name == "app_set_progress")
                {
                    var label = root.TryGetProperty("args", out var pa) && pa.ValueKind == JsonValueKind.Array && pa.GetArrayLength() > 0 ? pa[0].GetString() ?? "" : "";
                    Progress?.Invoke(label);
                    UpdateActiveDownloadProgress(label);
                }
                else if (name == "app_download_finished")
                {
                    var outcome = root.TryGetProperty("args", out var da) && da.ValueKind == JsonValueKind.Array && da.GetArrayLength() > 0 && da[0].ValueKind is JsonValueKind.True or JsonValueKind.False
                        ? da[0].GetBoolean()
                        : false;
                    ResolveFinish(outcome);
                }
            }
        }
        catch { ResolveFinish(null); }
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
                tracks.Add(new SpotiFlacTrack(IntProp(row, "index") ?? i, StringProp(row, "title") ?? "Untitled", StringProp(row, "artist") ?? "", StringProp(row, "album") ?? "", StringProp(row, "album_url"), StringProp(row, "cover"), NumberProp(row, "duration_ms") is { } d ? d / 1000 : null, row.TryGetProperty("explicit", out var ex) && ex.ValueKind == JsonValueKind.True, StringProp(row, "release_date")));
                i++;
            }
        }
        handler.Tcs.TrySetResult(new SpotiFlacTracklist(
            handler.Link,
            StringProp(header, "title") ?? tracks.FirstOrDefault()?.Album ?? "",
            StringProp(header, "artist") ?? "",
            StringProp(header, "cover") ?? tracks.FirstOrDefault()?.Cover,
            StringProp(header, "release_date"),
            StringProp(header, "description"),
            StringProp(header, "owner"),
            IntProp(header, "followers"),
            IntProp(header, "artist_listeners"),
            tracks));
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
