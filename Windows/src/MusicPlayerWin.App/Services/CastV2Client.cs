using System.Buffers.Binary;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace MusicPlayerWin.App.Services;

/// <summary>
/// Google Cast V2 sender for the default media receiver. The implementation
/// keeps the receiver transport id from RECEIVER_STATUS instead of assuming a
/// fixed destination and uses the protocol's 4-byte big-endian frame length.
/// </summary>
public sealed class CastV2Client : IAsyncDisposable
{
    private const string ConnectionNamespace = "urn:x-cast:com.google.cast.tp.connection";
    private const string ReceiverNamespace = "urn:x-cast:com.google.cast.receiver";
    private const string MediaNamespace = "urn:x-cast:com.google.cast.media";
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly object _gate = new();
    private TcpClient? _tcp;
    private SslStream? _ssl;
    private CancellationTokenSource? _receiveCts;
    private Task? _receiveLoop;
    private TaskCompletionSource<string?>? _transportWaiter;
    private string _transportId = "web-0";
    private int _requestId;
    private bool _disposed;

    public bool Connected => _tcp?.Connected == true && _ssl?.CanWrite == true;
    public string? ReceiverHost { get; private set; }
    public string TransportId { get { lock (_gate) return _transportId; } }
    public string Status { get; private set; } = "Disconnected";
    public event EventHandler<string>? StatusChanged;

    public async Task ConnectAsync(string host, int port = 8009, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await DisconnectAsync().ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(host)) throw new ArgumentException("Receiver host is required.", nameof(host));

        var tcp = new TcpClient();
        await tcp.ConnectAsync(host.Trim(), port, cancellationToken).ConfigureAwait(false);
        var ssl = new SslStream(tcp.GetStream(), leaveInnerStreamOpen: false, (_, _, _, _) => true);
        await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = host.Trim(),
            ApplicationProtocols = [new SslApplicationProtocol("castv2")]
        }, cancellationToken).ConfigureAwait(false);

        lock (_gate)
        {
            _tcp = tcp; _ssl = ssl; ReceiverHost = host.Trim(); _transportId = "web-0";
            Status = "Connected";
        }
        RaiseStatus();
        _receiveCts = new CancellationTokenSource();
        _receiveLoop = ReceiveLoopAsync(_receiveCts.Token);
        await SendAsync("receiver-0", ConnectionNamespace, new { type = "CONNECT", origin = new { } }, cancellationToken).ConfigureAwait(false);
    }

    public Task PlayAsync(CancellationToken cancellationToken = default) => SendMediaAsync(new { type = "PLAY", requestId = NextRequestId() }, cancellationToken);
    public Task PauseAsync(CancellationToken cancellationToken = default) => SendMediaAsync(new { type = "PAUSE", requestId = NextRequestId() }, cancellationToken);
    public Task StopAsync(CancellationToken cancellationToken = default) => SendMediaAsync(new { type = "STOP", requestId = NextRequestId() }, cancellationToken);
    public Task SeekAsync(double seconds, CancellationToken cancellationToken = default) => SendMediaAsync(new { type = "SEEK", requestId = NextRequestId(), currentTime = Math.Max(0, seconds) }, cancellationToken);
    public Task SetVolumeAsync(double volume, CancellationToken cancellationToken = default) => SendAsync("receiver-0", ReceiverNamespace, new { type = "SET_VOLUME", requestId = NextRequestId(), volume = new { level = Math.Clamp(volume, 0, 1) } }, cancellationToken);

    public async Task LoadUrlAsync(string url, string contentType = "audio/flac", CancellationToken cancellationToken = default)
    {
        if (!Connected) throw new InvalidOperationException("Cast device is not connected.");
        await SendAsync("receiver-0", ReceiverNamespace, new { type = "LAUNCH", requestId = NextRequestId(), appId = "CC1AD845" }, cancellationToken).ConfigureAwait(false);
        var waiter = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) _transportWaiter = waiter;
        string transport = "web-0";
        try { transport = await waiter.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken).ConfigureAwait(false) ?? "web-0"; }
        catch (TimeoutException) { transport = "web-0"; }
        finally { lock (_gate) if (ReferenceEquals(_transportWaiter, waiter)) _transportWaiter = null; }
        lock (_gate) _transportId = transport;
        await SendAsync(transport, ConnectionNamespace, new { type = "CONNECT", origin = new { } }, cancellationToken).ConfigureAwait(false);
        await SendMediaAsync(new { type = "LOAD", requestId = NextRequestId(), autoplay = true, currentTime = 0, media = new { contentId = url, streamType = "BUFFERED", contentType } }, cancellationToken).ConfigureAwait(false);
    }

    private Task SendMediaAsync(object payload, CancellationToken cancellationToken)
    {
        var destination = TransportId;
        return SendAsync(destination, MediaNamespace, payload, cancellationToken);
    }

    private int NextRequestId() => Interlocked.Increment(ref _requestId);

    private async Task SendAsync(string destination, string nameSpace, object payload, CancellationToken cancellationToken)
    {
        var ssl = _ssl ?? throw new InvalidOperationException("Cast device is not connected.");
        var json = JsonSerializer.SerializeToUtf8Bytes(payload);
        var proto = new List<byte>(json.Length + 128);
        WriteVarint(proto, (1 << 3) | 0); WriteVarint(proto, 1);
        WriteString(proto, 2, "sender-0");
        WriteString(proto, 3, destination);
        WriteString(proto, 4, nameSpace);
        WriteVarint(proto, (5 << 3) | 0); WriteVarint(proto, 0);
        WriteBytes(proto, 6, json);

        var header = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(header, proto.Count);
        await _sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await ssl.WriteAsync(header, cancellationToken).ConfigureAwait(false);
            await ssl.WriteAsync(proto.ToArray(), cancellationToken).ConfigureAwait(false);
            await ssl.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _sendGate.Release(); }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var ssl = _ssl;
        if (ssl is null) return;
        try
        {
            while (!cancellationToken.IsCancellationRequested && ssl.CanRead)
            {
                var header = await ReadExactAsync(ssl, 4, cancellationToken).ConfigureAwait(false);
                if (header is null) break;
                var length = BinaryPrimitives.ReadInt32BigEndian(header);
                if (length <= 0 || length > 8 * 1024 * 1024) break;
                var frame = await ReadExactAsync(ssl, length, cancellationToken).ConfigureAwait(false);
                if (frame is null) break;
                var json = ExtractPayload(frame);
                if (json is null) continue;
                HandleMessage(json.Value);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception ex) { AppLog.Warn("Cast receive loop stopped.", ex); }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_ssl, ssl)) Status = "Disconnected";
            }
            RaiseStatus();
        }
    }

    private void HandleMessage(JsonElement root)
    {
        try
        {
            if (root.TryGetProperty("type", out var type) && type.GetString() == "RECEIVER_STATUS" && root.TryGetProperty("status", out var status) && status.TryGetProperty("applications", out var apps) && apps.ValueKind == JsonValueKind.Array && apps.GetArrayLength() > 0)
            {
                var app = apps[0];
                var transport = app.TryGetProperty("transportId", out var tid) ? tid.GetString() : null;
                if (!string.IsNullOrWhiteSpace(transport))
                {
                    lock (_gate) _transportId = transport;
                    _transportWaiter?.TrySetResult(transport);
                }
            }
        }
        catch { }
    }

    private static async Task<byte[]?> ReadExactAsync(Stream stream, int count, CancellationToken cancellationToken)
    {
        var buffer = new byte[count]; var offset = 0;
        while (offset < count)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, count - offset), cancellationToken).ConfigureAwait(false);
            if (read == 0) return null;
            offset += read;
        }
        return buffer;
    }

    private static JsonElement? ExtractPayload(byte[] proto)
    {
        var offset = 0;
        while (offset < proto.Length)
        {
            if (!ReadVarint(proto, ref offset, out var key)) break;
            var field = (int)(key >> 3); var wire = (int)(key & 7);
            if (field == 6 && wire == 2 && ReadVarint(proto, ref offset, out var length) && length <= (ulong)(proto.Length - offset))
            {
                try
                {
                    using var doc = JsonDocument.Parse(proto.AsMemory(offset, checked((int)length)));
                    return doc.RootElement.Clone();
                }
                catch { return null; }
            }
            if (!Skip(proto, ref offset, wire)) break;
        }
        return null;
    }

    private static bool Skip(byte[] data, ref int offset, int wireType)
    {
        switch (wireType)
        {
            case 0: return ReadVarint(data, ref offset, out _);
            case 1: offset += 8; return offset <= data.Length;
            case 2:
                if (!ReadVarint(data, ref offset, out var len) || len > (ulong)(data.Length - offset)) return false;
                offset += (int)len; return true;
            case 5: offset += 4; return offset <= data.Length;
            default: return false;
        }
    }

    private static bool ReadVarint(byte[] data, ref int offset, out ulong value)
    {
        value = 0; var shift = 0;
        while (offset < data.Length && shift <= 63)
        {
            var b = data[offset++]; value |= (ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return true; shift += 7;
        }
        return false;
    }

    private static void WriteString(List<byte> bytes, int field, string value) => WriteBytes(bytes, field, Encoding.UTF8.GetBytes(value));
    private static void WriteBytes(List<byte> bytes, int field, byte[] value) { WriteVarint(bytes, (uint)((field << 3) | 2)); WriteVarint(bytes, (uint)value.Length); bytes.AddRange(value); }
    private static void WriteVarint(List<byte> bytes, uint value) { while (value >= 0x80) { bytes.Add((byte)(value | 0x80)); value >>= 7; } bytes.Add((byte)value); }

    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        await DisconnectAsync().ConfigureAwait(false);
    }

    private async Task DisconnectAsync()
    {
        _receiveCts?.Cancel();
        try { if (_receiveLoop is not null) await _receiveLoop.WaitAsync(TimeSpan.FromSeconds(1)).ConfigureAwait(false); } catch { }
        _receiveCts?.Dispose(); _receiveCts = null; _receiveLoop = null;
        try { if (_ssl is not null) await _ssl.DisposeAsync().ConfigureAwait(false); } catch { }
        _ssl = null; _tcp?.Dispose(); _tcp = null;
        lock (_gate) { ReceiverHost = null; _transportId = "web-0"; Status = "Disconnected"; }
        RaiseStatus();
    }

    private void RaiseStatus() => StatusChanged?.Invoke(this, Status);
    private void ThrowIfDisposed() { if (_disposed) throw new ObjectDisposedException(nameof(CastV2Client)); }
}
