using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Playlists;

namespace MusicPlayerWin.Core.Tests;

public sealed class PlaylistStoreTests
{
    [Fact]
    public void CreatesUniqueDefaultNamesAndPersistsEntries()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        try
        {
            var store = new PlaylistStore(root);
            var first = store.Create();
            var second = store.Create();
            Assert.Equal("New Playlist", first.Name);
            Assert.Equal("New Playlist 2", second.Name);

            var track = new LibraryTrack
            {
                Id = new Uri("file:///C:/Music/one.flac"),
                Title = "One",
                Artist = "Artist",
                AlbumArtist = "Artist",
                Album = "Album",
                Duration = 180,
                HasLyrics = false
            };
            store.Add(first.Id, [track]);

            var reloaded = new PlaylistStore(root);
            var loaded = reloaded.Find(first.Id);
            Assert.NotNull(loaded);
            Assert.Single(loaded!.Entries);
            Assert.Equal("One", loaded.Entries[0].Title);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }
}
