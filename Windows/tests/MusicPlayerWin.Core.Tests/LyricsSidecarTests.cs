using MusicPlayerWin.Core.Lyrics;

namespace MusicPlayerWin.Core.Tests;

public sealed class LyricsSidecarTests
{
    [Fact]
    public async Task SaveAndLoad_LocalSidecar_RoundTrips()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var audio = new Uri(Path.Combine(root, "song.flac"));
            await File.WriteAllBytesAsync(audio.LocalPath, [0]);
            const string lrc = "[ar:Artist]\n[00:01.00]Hello";

            Assert.True(await LyricsSidecar.SaveAsync(audio, lrc));
            Assert.True(LyricsSidecar.Exists(audio));

            var parsed = await LyricsSidecar.LoadAsync(audio);
            Assert.NotNull(parsed);
            Assert.Equal("Artist", parsed!.Artist);
            Assert.Equal("Hello", parsed.Lines[0].Text);
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
    }
}
