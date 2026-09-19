using System.Net;
using System.Net.Sockets;
using System.Text;

namespace MusicPlayerWin.App.Services;

public sealed record CastDevice(string Name, string Host, int Port, string? Model = null);

public sealed class CastDiscoveryService
{
    private const string ServiceName = "_googlecast._tcp.local";
    private static readonly IPAddress MulticastAddress = IPAddress.Parse("224.0.0.251");

    public async Task<IReadOnlyList<CastDevice>> DiscoverAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        timeout ??= TimeSpan.FromSeconds(2);
        using var udp = new UdpClient(AddressFamily.InterNetwork);
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
        try { udp.JoinMulticastGroup(MulticastAddress); } catch { }
        var query = BuildQuery(ServiceName, 12);
        await udp.SendAsync(query, query.Length, new IPEndPoint(MulticastAddress, 5353), cancellationToken).ConfigureAwait(false);

        var instances = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var srvs = new Dictionary<string, (string host, int port)>(StringComparer.OrdinalIgnoreCase);
        var addresses = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var end = DateTime.UtcNow + timeout.Value;
        while (DateTime.UtcNow < end)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var remaining = end - DateTime.UtcNow;
            if (remaining <= TimeSpan.Zero) break;
            var receive = udp.ReceiveAsync(cancellationToken).AsTask();
            var completed = await Task.WhenAny(receive, Task.Delay(remaining, cancellationToken)).ConfigureAwait(false);
            if (completed != receive) break;
            var packet = await receive.ConfigureAwait(false);
            ParsePacket(packet.Buffer, instances, srvs, addresses, names);
        }

        var result = new List<CastDevice>();
        foreach (var service in instances)
        {
            if (!srvs.TryGetValue(service.Key, out var srv)) continue;
            var host = srv.host.TrimEnd('.');
            if (!addresses.TryGetValue(host, out var ip)) continue;
            var friendly = names.TryGetValue(service.Key, out var text) ? text : service.Key.Split('.')[0];
            result.Add(new CastDevice(friendly, ip, srv.port));
        }
        return result.GroupBy(x => $"{x.Host}:{x.Port}", StringComparer.OrdinalIgnoreCase).Select(x => x.First()).OrderBy(x => x.Name).ToArray();
    }

    private static byte[] BuildQuery(string name, ushort type)
    {
        var data = new List<byte> { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
        foreach (var label in name.Split('.')) { data.Add((byte)label.Length); data.AddRange(Encoding.ASCII.GetBytes(label)); }
        data.Add(0); data.Add((byte)(type >> 8)); data.Add((byte)type); data.Add(0); data.Add(1);
        return data.ToArray();
    }

    private static void ParsePacket(byte[] data, Dictionary<string, string> instances, Dictionary<string, (string host, int port)> srvs, Dictionary<string, string> addresses, Dictionary<string, string> names)
    {
        try
        {
            if (data.Length < 12) return;
            var qd = ReadU16(data, 4); var an = ReadU16(data, 6); var ns = ReadU16(data, 8); var ar = ReadU16(data, 10);
            var offset = 12;
            for (var i = 0; i < qd; i++) { _ = ReadName(data, ref offset); offset += 4; if (offset > data.Length) return; }
            for (var i = 0; i < an + ns + ar; i++)
            {
                var name = ReadName(data, ref offset); if (offset + 10 > data.Length) return;
                var type = ReadU16(data, offset); var cls = ReadU16(data, offset + 2); var len = ReadU16(data, offset + 8); offset += 10;
                if (offset + len > data.Length) return;
                var rdata = offset;
                if (type == 12) instances[ name ] = ReadName(data, ref rdata);
                else if (type == 33 && len >= 6) { var port = ReadU16(data, offset + 4); rdata = offset + 6; srvs[name] = (ReadName(data, ref rdata), port); }
                else if (type == 1 && len == 4) addresses[name] = new IPAddress(data.Skip(offset).Take(4).ToArray()).ToString();
                else if (type == 16 && len > 0) ParseTxt(data, offset, len, name, names);
                offset += len;
            }
        }
        catch { }
    }

    private static void ParseTxt(byte[] data, int offset, int length, string name, Dictionary<string, string> names)
    {
        var end = offset + length;
        while (offset < end)
        {
            var n = data[offset++]; if (offset + n > end) break;
            var text = Encoding.UTF8.GetString(data, offset, n); offset += n;
            if (text.StartsWith("fn=", StringComparison.OrdinalIgnoreCase)) names[name] = text[3..];
        }
    }

    private static ushort ReadU16(byte[] data, int offset) => (ushort)((data[offset] << 8) | data[offset + 1]);

    private static string ReadName(byte[] data, ref int offset)
    {
        var labels = new List<string>(); var cursor = offset; var jumped = false; var guard = 0;
        while (cursor < data.Length && guard++ < 64)
        {
            var len = data[cursor++];
            if (len == 0) { if (!jumped) offset = cursor; break; }
            if ((len & 0xC0) == 0xC0)
            {
                if (cursor >= data.Length) break;
                var pointer = ((len & 0x3F) << 8) | data[cursor++];
                if (!jumped) offset = cursor; jumped = true; cursor = pointer; continue;
            }
            if (cursor + len > data.Length) break;
            labels.Add(Encoding.UTF8.GetString(data, cursor, len)); cursor += len;
        }
        return string.Join('.', labels);
    }
}
