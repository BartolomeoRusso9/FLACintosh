using MusicPlayerWin.Core.Library;
using System.Text.Json;
using MusicPlayerWin.Core.Infrastructure;

namespace MusicPlayerWin.Core.Servers;

public sealed record MusicServer
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required MusicServerKind Kind { get; init; }
    public required string Name { get; init; }
    public required Uri Address { get; init; }
    public required string Username { get; init; }

    public string PasswordKey => $"server-{Id:N}";
}

public enum MusicServerKind
{
    Subsonic,
    Jellyfin
}

public sealed record ServerPlaylist(
    string Id,
    string Name,
    IReadOnlyList<Uri> TrackUrls,
    Guid ServerId)
{
    public string ServerName { get; init; } = string.Empty;
    public string DisplayName => string.IsNullOrWhiteSpace(ServerName) ? Name : $"{Name} · {ServerName}";
}

public interface IMusicServerClient
{
    Task<IReadOnlyList<LibraryAlbum>> AlbumsAsync(
        Action<int, int>? progress = null,
        CancellationToken cancellationToken = default);

    Task<byte[]?> CoverAsync(string albumId, CancellationToken cancellationToken = default);

    Uri? StreamUri(string trackId);

    Task<IReadOnlyList<ServerPlaylist>> PlaylistsAsync(CancellationToken cancellationToken = default);

    Task PingAsync(CancellationToken cancellationToken = default);
}

public static class ServerDate
{
    public static DateTimeOffset? Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = System.Text.RegularExpressions.Regex.Replace(value, @"\.\d+", "");
        return DateTimeOffset.TryParse(
            normalized,
            System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
            out var result) ? result : null;
    }
}

public sealed class MusicServerStore
{
    private readonly object _gate = new();
    private readonly string _filePath;
    private List<MusicServer> _servers;

    public MusicServerStore(string? applicationDataRoot = null)
    {
        var root = applicationDataRoot
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(root);
        _filePath = Path.Combine(root, "servers.json");
        _servers = Load();
    }

    public IReadOnlyList<MusicServer> Servers
    {
        get { lock (_gate) return _servers.ToArray(); }
    }

    public void Add(MusicServer server)
    {
        lock (_gate)
        {
            _servers.RemoveAll(x => x.Id == server.Id);
            _servers.Add(server);
            SaveLocked();
        }
    }

    public void Update(MusicServer server) => Add(server);

    public void Remove(Guid id)
    {
        lock (_gate)
        {
            _servers.RemoveAll(x => x.Id == id);
            SaveLocked();
        }
    }

    public MusicServer? Find(Guid id)
    {
        lock (_gate) return _servers.FirstOrDefault(x => x.Id == id);
    }

    private List<MusicServer> Load()
    {
        try
        {
            var json = File.ReadAllText(_filePath);
            return JsonSerializer.Deserialize<List<MusicServer>>(json) ?? [];
        }
        catch
        {
            return [];
        }
    }

    private void SaveLocked()
    {
        var json = JsonSerializer.Serialize(_servers, new JsonSerializerOptions { WriteIndented = true });
        AtomicFile.WriteAllText(_filePath, json);
    }
}

public static class MusicServerFactory
{
    public static IMusicServerClient Create(MusicServer server, string password, HttpClient? httpClient = null) =>
        server.Kind switch
        {
            MusicServerKind.Jellyfin => new JellyfinClient(server, password, httpClient),
            MusicServerKind.Subsonic => new SubsonicClient(server, password, httpClient),
            _ => throw new ArgumentOutOfRangeException(nameof(server.Kind))
        };
}

public static class ServerUrl
{
    public static Uri WithQuery(Uri baseUri, IEnumerable<KeyValuePair<string, string>> parameters)
    {
        var builder = new UriBuilder(baseUri);
        var existing = builder.Query.TrimStart('?', ' ');
        var added = parameters.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}");
        builder.Query = string.Join("&", new[] { existing }.Where(x => !string.IsNullOrWhiteSpace(x)).Concat(added));
        return builder.Uri;
    }
}
