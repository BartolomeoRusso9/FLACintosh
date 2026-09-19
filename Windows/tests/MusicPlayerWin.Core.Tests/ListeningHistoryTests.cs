using MusicPlayerWin.Core.History;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.Core.Tests;

public partial class ListeningHistoryTests
{
    [Fact]
    public void HalfPlayedTrackCountsAsPlay()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var history = new ListeningHistoryStore(root);
            history.Start(Track("Song", 180));
            history.Accumulate(90);
            history.Finish();
            Assert.Equal(1, history.Summary().Plays);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void ShortTrackDoesNotCount()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var history = new ListeningHistoryStore(root);
            history.Start(Track("Short", 20));
            history.Accumulate(20);
            history.Finish();
            Assert.Equal(0, history.Summary().Plays);
        }
        finally { Directory.Delete(root, true); }
    }

    private static LibraryTrack Track(string title, double duration) => new()
    {
        Id = new Uri("file:///music/" + title + ".flac"),
        Title = title,
        Artist = "Artist",
        AlbumArtist = "Artist",
        Album = "Album",
        Duration = duration,
        HasLyrics = false
    };
}

namespace MusicPlayerWin.Core.Tests;

public partial class ListeningHistoryTests
{
    [Fact]
    public void Clear_RemovesPersistedHistory()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var history = new ListeningHistoryStore(root);
            history.Start(Track("Clear Me", 180));
            history.Accumulate(120);
            history.Finish();
            Assert.Equal(1, history.Summary().Plays);
            history.Clear();
            Assert.Equal(0, history.Summary().Plays);
            Assert.Empty(history.Recent());
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }
}
