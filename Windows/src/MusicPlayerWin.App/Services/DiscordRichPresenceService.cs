using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Services;

public sealed class DiscordRichPresenceService : IAsyncDisposable
{
    private NamedPipeClientStream? _pipe;
    private CancellationTokenSource? _cts;
    private string _applicationId = "";
    private bool _enabled;
    private string? _lastKey;
    private DateTimeOffset _start;
    private readonly Dictionary<string, string?> _artworkCache = new(StringComparer.OrdinalIgnoreCase);
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };

    public bool Enabled => _enabled;
    public bool Connected => _pipe?.IsConnected == true;
    public string Status => !_enabled ? "Off" : string.IsNullOrWhiteSpace(_applicationId) ? "Needs application ID" : Connected ? "Connected" : "Waiting for Discord";

    public async Task ConfigureAsync(bool enabled, string applicationId, bool showArtwork, LibraryTrack? current = null, bool isPlaying = false, CancellationToken cancellationToken = default)
    {
        _enabled = enabled;
        _applicationId = applicationId.Trim();
        _lastKey = null;
        if (!_enabled || !ulong.TryParse(_applicationId, out _))
        {
            await DisconnectAsync().ConfigureAwait(false);
            return;
        }
        await ConnectAsync(cancellationToken).ConfigureAwait(false);
        await UpdateAsync(current, isPlaying, showArtwork, cancellationToken).ConfigureAwait(false);
    }

    public async Task UpdateAsync(LibraryTrack? track, bool isPlaying, bool showArtwork, CancellationToken cancellationToken = default)
    {
        if (!_enabled || string.IsNullOrWhiteSpace(_applicationId)) return;
        if (!Connected) await ConnectAsync(cancellationToken).ConfigureAwait(false);
        if (!Connected) return;

        if (!isPlaying || track is null || string.IsNullOrWhiteSpace(track.Title))
        {
            if (_lastKey != "")
            {
                await SendCommandAsync(1, new { cmd = "SET_ACTIVITY", args = new { pid = Environment.ProcessId, activity = (object?)null }, nonce = Guid.NewGuid().ToString("N") }, cancellationToken).ConfigureAwait(false);
                _lastKey = "";
            }
            return;
        }

        var duration = track.Duration is > 0 ? (long?)Math.Round(track.Duration.Value) : null;
        var key = $"{track.Title}|{track.Artist}|{track.Album}|{duration}|{showArtwork}|{Math.Floor(DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 3d)}";
        if (key == _lastKey) return;
        _lastKey = key;
        _start = DateTimeOffset.UtcNow;

        var activity = new Dictionary<string, object?>
        {
            ["type"] = 2,
            ["status_display_type"] = 1,
            ["details"] = Field(track.Title),
            ["state"] = Field(track.Artist),
            ["timestamps"] = duration is null ? new { start = _start.ToUnixTimeMilliseconds() } : new { start = _start.ToUnixTimeMilliseconds(), end = _start.AddSeconds(duration.Value).ToUnixTimeMilliseconds() }
        };
        if (!string.IsNullOrWhiteSpace(track.Album))
        {
            var assets = new Dictionary<string, object?> { ["large_text"] = Field(track.Album) };
            if (showArtwork && (await FindArtworkAsync(track.Artist, track.Album, track.Title, cancellationToken).ConfigureAwait(false)) is { Length: > 0 } artwork)
                assets["large_image"] = artwork;
            activity["assets"] = assets;
        }
        await SendCommandAsync(1, new { cmd = "SET_ACTIVITY", args = new { pid = Environment.ProcessId, activity }, nonce = Guid.NewGuid().ToString("N") }, cancellationToken).ConfigureAwait(false);
    }

    private async Task ConnectAsync(CancellationToken cancellationToken)
    {
        if (!_enabled || !ulong.TryParse(_applicationId, out _)) return;
        await DisconnectAsync().ConfigureAwait(false);
        for (var i = 0; i < 10; i++)
        {
            try
            {
                var pipe = new NamedPipeClientStream(".", $"discord-ipc-{i}", PipeDirection.InOut, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(250, cancellationToken).ConfigureAwait(false);
                _pipe = pipe;
                _cts = new CancellationTokenSource();
                await SendCommandAsync(0, new { v = 1, client_id = _applicationId }, cancellationToken).ConfigureAwait(false);
                _ = Task.Run(() => ReadLoopAsync(pipe, _cts.Token));
                return;
            }
            catch { }
        }
    }

    private async Task ReadLoopAsync(NamedPipeClientStream pipe, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested && pipe.IsConnected)
            {
                var header = await ReadExactAsync(pipe, 8, cancellationToken).ConfigureAwait(false);
                if (header is null) break;
                var opcode = BitConverter.ToUInt32(header, 0);
                var length = checked((int)BitConverter.ToUInt32(header, 4));
                if (length < 0 || length > 4 * 1024 * 1024) break;
                var body = length == 0 ? Array.Empty<byte>() : await ReadExactAsync(pipe, length, cancellationToken).ConfigureAwait(false);
                if (body is null) break;
                if (opcode == 1)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(body);
                        if (doc.RootElement.TryGetProperty("evt", out var evt) && evt.GetString() == "ERROR")
                            _lastKey = null;
                    }
                    catch { }
                }
                else if (opcode == 3)
                {
                    await SendCommandAsync(4, JsonSerializer.Deserialize<JsonElement>(body), cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch { }
        finally
        {
            if (ReferenceEquals(_pipe, pipe))
            {
                await DisconnectAsync().ConfigureAwait(false);
            }
        }
    }

    private async Task SendCommandAsync(uint opcode, object payload, CancellationToken cancellationToken)
    {
        if (_pipe is null || !_pipe.IsConnected) return;
        var json = payload is JsonElement element ? Encoding.UTF8.GetBytes(element.GetRawText()) : JsonSerializer.SerializeToUtf8Bytes(payload);
        var header = new byte[8];
        BitConverter.GetBytes(opcode).CopyTo(header, 0);
        BitConverter.GetBytes(json.Length).CopyTo(header, 4);
        await _pipe.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        if (json.Length > 0) await _pipe.WriteAsync(json, cancellationToken).ConfigureAwait(false);
        await _pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<byte[]?> ReadExactAsync(Stream stream, int count, CancellationToken cancellationToken)
    {
        var data = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var read = await stream.ReadAsync(data.AsMemory(offset, count - offset), cancellationToken).ConfigureAwait(false);
            if (read <= 0) return null;
            offset += read;
        }
        return data;
    }

    private async Task<string?> FindArtworkAsync(string artist, string album, string title, CancellationToken cancellationToken)
    {
        var key = $"{artist}|{album}|{title}";
        if (_artworkCache.TryGetValue(key, out var cached)) return cached;
        try
        {
            var term = Uri.EscapeDataString($"{artist} {(!string.IsNullOrWhiteSpace(album) ? album : title)}");
            using var response = await _http.GetAsync($"https://itunes.apple.com/search?term={term}&entity=album&limit=10", cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) { _artworkCache[key] = null; return null; }
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false));
            foreach (var row in doc.RootElement.GetProperty("results").EnumerateArray())
            {
                var foundArtist = row.TryGetProperty("artistName", out var a) ? a.GetString() : null;
                var foundAlbum = row.TryGetProperty("collectionName", out var al) ? al.GetString() : null;
                if (!TextEquals(foundArtist, artist) || (!string.IsNullOrWhiteSpace(album) && !TextEquals(foundAlbum, album))) continue;
                var image = row.TryGetProperty("artworkUrl100", out var i) ? i.GetString() : null;
                if (image is not null) image = image.Replace("100x100bb", "512x512bb", StringComparison.OrdinalIgnoreCase);
                _artworkCache[key] = image; return image;
            }
        }
        catch { }
        _artworkCache[key] = null; return null;
    }

    private static bool TextEquals(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        static string N(string value) => new string(value.Normalize(System.Text.NormalizationForm.FormD).Where(ch => !System.Globalization.CharUnicodeInfo.GetUnicodeCategory(ch).Equals(System.Globalization.UnicodeCategory.NonSpacingMark)).ToArray()).ToLowerInvariant().Replace(" ", "").Replace("-", "");
        return N(left).Contains(N(right), StringComparison.Ordinal) || N(right).Contains(N(left), StringComparison.Ordinal);
    }

    private static string Field(string text)
    {
        var value = new string(text.Trim().Take(128).ToArray());
        return value.Length < 2 ? value.PadRight(2, ' ') : value;
    }

    public async ValueTask DisposeAsync() { _http.Dispose(); await DisconnectAsync().ConfigureAwait(false); }

    private async Task DisconnectAsync()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;
        if (_pipe is not null)
        {
            try { await _pipe.DisposeAsync().ConfigureAwait(false); } catch { }
            _pipe = null;
        }
    }
}
