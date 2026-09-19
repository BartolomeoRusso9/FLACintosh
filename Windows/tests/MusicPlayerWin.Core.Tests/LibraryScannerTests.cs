using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.Core.Tests;

public sealed class LibraryScannerTests
{
    [Fact]
    public void AudioExtensions_MatchExpectedFormats_CaseInsensitive()
    {
        Assert.Contains(".flac", LibraryScanner.AudioExtensions, StringComparer.OrdinalIgnoreCase);
        Assert.Contains(".dsf", LibraryScanner.AudioExtensions, StringComparer.OrdinalIgnoreCase);
        Assert.Contains(".mp3", LibraryScanner.AudioExtensions, StringComparer.OrdinalIgnoreCase);
        Assert.True(LibraryScanner.AudioExtensions.Contains(".FLAC"));
        Assert.False(LibraryScanner.AudioExtensions.Contains(".jpg"));
    }

    [Fact]
    public void AlbumId_FoldsCaseAndTrims()
    {
        Assert.Equal(
            LibraryScanner.AlbumId(" Artist ", " Album "),
            LibraryScanner.AlbumId("artist", "album"));
    }

    [Fact]
    public void Store_GroupsAndSortsLibrary()
    {
        static LibraryTrack Track(string title, string album, string artist, int number) => new()
        {
            Id = new Uri($"file:///music/{artist}/{album}/{number:00}-{title}.flac"),
            Title = title,
            Artist = artist,
            AlbumArtist = artist,
            Album = album,
            TrackNumber = number,
            HasLyrics = number == 1,
            Duration = 120
        };

        var store = new LibraryStore();
        store.AddBatch([
            Track("B", "Record", "Artist", 2),
            Track("A", "Record", "Artist", 1),
            Track("Only", "Another", "Artist", 1)
        ]);

        Assert.Equal(2, store.Albums.Count);
        Assert.Equal(["Another", "Record"], store.Albums.Select(a => a.Title).ToArray());
        Assert.Equal(["A", "B"], store.Albums.Single(a => a.Title == "Record").Tracks.Select(t => t.Title).ToArray());
        Assert.Single(store.Artists);
        Assert.Equal(3, store.Songs.Count);
    }
}
