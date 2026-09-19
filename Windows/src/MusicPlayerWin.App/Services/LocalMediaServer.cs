using System.Net;
using System.Net.Sockets;
using System.Text;

namespace MusicPlayerWin.App.Services;

/// <summary>Minimal range-capable HTTP server used only while Google Cast streams a local file.</summary>
public sealed class LocalMediaServer : IAsyncDisposable
{
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private string? _file;
    private int _port;
    private string _token = Guid.NewGuid().ToString("N");

    public bool Running => _listener is not null;
    public Uri? CurrentUri { get; private set; }

    public async Task<Uri> PublishAsync(string file, string receiverHost, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(file)) throw new FileNotFoundException("Media file not found.", file);
        await StopAsync().ConfigureAwait(false);
        _file = Path.GetFullPath(file);
        _token = Guid.NewGuid().ToString("N");
        _listener = new TcpListener(IPAddress.Any, 0);
        _listener.Start();
        _port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _cts = new CancellationTokenSource();
        _ = AcceptLoopAsync(_cts.Token);
        var localIp = ResolveLocalAddress(receiverHost);
        CurrentUri = new Uri($"http://{localIp}:{_port}/media/{_token}");
        return CurrentUri;
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && _listener is not null)
        {
            try
            {
                var client = await _listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                _ = HandleAsync(client, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch { break; }
        }
    }

    private async Task HandleAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using var clientScope = client;
        using var stream = client.GetStream();
        try
        {
            var request = await ReadRequestAsync(stream, cancellationToken).ConfigureAwait(false);
            if (request is null || _file is null)
            {
                await WriteResponseAsync(stream, 400, "text/plain", "Bad request\n"u8.ToArray(), cancellationToken).ConfigureAwait(false); return;
            }
            if (request.Path != $"/media/{_token}")
            {
                await WriteResponseAsync(stream, 404, "text/plain", "Not found\n"u8.ToArray(), cancellationToken).ConfigureAwait(false); return;
            }

            var info = new FileInfo(_file);
            var length = info.Length;
            long start = 0, end = length - 1;
            var partial = false;
            if (request.Range is { } range)
            {
                partial = true;
                start = Math.Max(0, range.start);
                end = range.end ?? Math.Max(0, length - 1);
                if (start >= length || start > end)
                {
                    await WriteRawAsync(stream, $"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{length}\r\nConnection: close\r\n\r\n", cancellationToken).ConfigureAwait(false); return;
                }
                end = Math.Min(end, length - 1);
            }
            var bodyLength = end - start + 1;
            var mime = ContentType(_file);
            var status = partial ? "206 Partial Content" : "200 OK";
            var header = $"HTTP/1.1 {status}\r\nContent-Type: {mime}\r\nAccept-Ranges: bytes\r\nContent-Length: {bodyLength}\r\nContent-Disposition: inline; filename=\"{SanitizeFileName(Path.GetFileName(_file))}\"\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n{(partial ? $"Content-Range: bytes {start}-{end}/{length}\r\n" : "")}\r\n";
            await WriteRawAsync(stream, header, cancellationToken).ConfigureAwait(false);
            if (request.Method == "HEAD") return;

            await using var file = new FileStream(_file, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            file.Position = start;
            var buffer = new byte[128 * 1024];
            var remaining = bodyLength;
            while (remaining > 0)
            {
                var read = await file.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), cancellationToken).ConfigureAwait(false);
                if (read <= 0) break;
                await stream.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                remaining -= read;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception ex) { AppLog.Warn("Local media request failed.", ex); }
    }

    private static async Task<(string Method, string Path, (long start, long? end)? Range)?> ReadRequestAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var ms = new MemoryStream();
        var buffer = new byte[1024];
        while (ms.Length < 32 * 1024)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            ms.Write(buffer, 0, read);
            if (ms.Length >= 4 && ms.ToArray()[^4..].SequenceEqual("\r\n\r\n"u8.ToArray())) break;
        }
        var text = Encoding.ASCII.GetString(ms.ToArray());
        var lines = text.Split("\r\n", StringSplitOptions.None);
        var requestLine = lines.FirstOrDefault() ?? "";
        var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        (long start, long? end)? range = null;
        var rangeLine = lines.FirstOrDefault(x => x.StartsWith("Range:", StringComparison.OrdinalIgnoreCase));
        if (rangeLine is not null)
        {
            var value = rangeLine[(rangeLine.IndexOf(':') + 1)..].Trim();
            if (value.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) value = value[6..];
            var pieces = value.Split('-', 2);
            if (long.TryParse(pieces[0], out var start))
            {
                long? end = pieces.Length > 1 && long.TryParse(pieces[1], out var parsed) ? parsed : null;
                range = (start, end);
            }
        }
        return (parts[0].ToUpperInvariant(), parts[1], range);
    }

    private static async Task WriteResponseAsync(NetworkStream stream, int status, string contentType, byte[] body, CancellationToken cancellationToken)
    {
        await WriteRawAsync(stream, $"HTTP/1.1 {status}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", cancellationToken).ConfigureAwait(false);
        if (body.Length > 0) await stream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteRawAsync(NetworkStream stream, string header, CancellationToken cancellationToken) => await stream.WriteAsync(Encoding.ASCII.GetBytes(header), cancellationToken).ConfigureAwait(false);

    private static string ContentType(string file) => Path.GetExtension(file).ToLowerInvariant() switch
    {
        ".mp3" => "audio/mpeg", ".m4a" or ".m4b" or ".aac" => "audio/mp4", ".wav" => "audio/wav", ".aif" or ".aiff" => "audio/aiff", ".ogg" or ".oga" => "audio/ogg", ".opus" => "audio/ogg", ".flac" => "audio/flac", ".wma" => "audio/x-ms-wma", _ => "application/octet-stream"
    };

    private static string SanitizeFileName(string name) => string.Concat(name.Select(c => c is '"' or '\r' or '\n' ? '_' : c));

    private static string ResolveLocalAddress(string receiverHost)
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try { socket.Connect(receiverHost, 8009); return ((IPEndPoint)socket.LocalEndPoint!).Address.ToString(); }
        catch { return "127.0.0.1"; }
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);
    private Task StopAsync()
    {
        try { _cts?.Cancel(); } catch { }
        _cts?.Dispose(); _cts = null;
        try { _listener?.Stop(); } catch { }
        _listener = null; _file = null; CurrentUri = null;
        return Task.CompletedTask;
    }
}
