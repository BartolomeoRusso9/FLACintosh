using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace MusicPlayerWin.Core.Library;

public static class RemoteCache
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MusicPlayerWin", "Cache");

    public static string Fingerprint(Uri url)
    {
        var builder = new UriBuilder(url);
        var id = ParseQuery(url, "id");
        builder.Query = id is null ? string.Empty : $"id={Uri.EscapeDataString(id)}";
        var bytes = Encoding.UTF8.GetBytes(builder.Uri.AbsoluteUri);
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()[..24];
    }

    public static async Task<Uri> FileAsync(Uri url, CancellationToken cancellationToken = default)
    {
        if (url.IsFile) return url;
        Directory.CreateDirectory(Root);
        var prefix = Fingerprint(url);
        var existing = Directory.EnumerateFiles(Root, prefix + ".*").FirstOrDefault();
        if (existing is not null) return new Uri(existing);

        await Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            existing = Directory.EnumerateFiles(Root, prefix + ".*").FirstOrDefault();
            if (existing is not null) return new Uri(existing);

            using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var ext = GuessExtension(response.Content.Headers.ContentType?.MediaType, url);
            var target = Path.Combine(Root, prefix + ext);
            var temp = target + ".download";
            await using (var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
            await using (var output = File.Create(temp))
                await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
            File.Move(temp, target, true);
            File.SetLastWriteTimeUtc(target, DateTime.UtcNow);
            return new Uri(target);
        }
        finally { Gate.Release(); }
    }

    public static long Size()
    {
        Directory.CreateDirectory(Root);
        return Directory.EnumerateFiles(Root).Sum(path => new FileInfo(path).Length);
    }

    public static void Empty()
    {
        if (!Directory.Exists(Root)) return;
        foreach (var path in Directory.EnumerateFiles(Root))
        {
            try { File.Delete(path); } catch { }
        }
    }

    public static async Task EnforceLimitAsync(long maxBytes, CancellationToken cancellationToken = default)
    {
        if (maxBytes <= 0) return;
        await Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var files = Directory.Exists(Root)
                ? Directory.EnumerateFiles(Root).Select(path => new FileInfo(path)).OrderBy(x => x.LastWriteTimeUtc).ToList()
                : [];
            var size = files.Sum(x => x.Length);
            foreach (var file in files)
            {
                if (size <= maxBytes) break;
                try { file.Delete(); size -= file.Length; } catch { }
            }
        }
        finally { Gate.Release(); }
    }

    public static void Touch(Uri file)
    {
        if (!file.IsFile) return;
        try { File.SetLastWriteTimeUtc(file.LocalPath, DateTime.UtcNow); } catch { }
    }

    private static string? ParseQuery(Uri url, string name)
    {
        foreach (var pair in url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            if (parts.Length == 2 && string.Equals(Uri.UnescapeDataString(parts[0]), name, StringComparison.OrdinalIgnoreCase))
                return Uri.UnescapeDataString(parts[1]);
        }
        return null;
    }

    private static string GuessExtension(string? mediaType, Uri url)
    {
        var existing = Path.GetExtension(url.AbsolutePath);
        if (!string.IsNullOrWhiteSpace(existing) && existing.Length <= 6) return existing.ToLowerInvariant();
        return mediaType?.ToLowerInvariant() switch
        {
            "audio/flac" => ".flac", "audio/mpeg" => ".mp3", "audio/mp4" => ".m4a", "audio/aac" => ".aac",
            "audio/wav" => ".wav", "audio/ogg" => ".ogg", "audio/opus" => ".opus", "audio/x-m4a" => ".m4a", _ => ".bin"
        };
    }
}
