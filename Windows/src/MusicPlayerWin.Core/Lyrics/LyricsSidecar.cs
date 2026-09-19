namespace MusicPlayerWin.Core.Lyrics;

/// <summary>Reads/writes .lrc sidecars beside local audio files.</summary>
public static class LyricsSidecar
{
    public static bool Exists(Uri audio)
    {
        if (!audio.IsFile) return false;
        return File.Exists(Path.ChangeExtension(audio.LocalPath, ".lrc"));
    }

    public static async Task<TimedLyrics?> LoadAsync(
        Uri audio,
        CancellationToken cancellationToken = default)
    {
        if (!audio.IsFile) return null;
        var sidecar = Path.ChangeExtension(audio.LocalPath, ".lrc");
        if (!File.Exists(sidecar)) return null;

        var source = await File.ReadAllTextAsync(sidecar, cancellationToken).ConfigureAwait(false);
        var lyrics = EnhancedLrc.Parse(source);
        return lyrics.IsEmpty ? null : lyrics;
    }

    public static async Task<bool> SaveAsync(
        Uri audio,
        string lrc,
        CancellationToken cancellationToken = default)
    {
        if (!audio.IsFile || string.IsNullOrWhiteSpace(lrc)) return false;
        var sidecar = Path.ChangeExtension(audio.LocalPath, ".lrc");
        try
        {
            await File.WriteAllTextAsync(sidecar, lrc, cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}
