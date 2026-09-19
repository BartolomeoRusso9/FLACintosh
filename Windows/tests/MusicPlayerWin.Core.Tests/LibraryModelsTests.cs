using MusicPlayerWin.Core.Library;
using Xunit;

namespace MusicPlayerWin.Core.Tests;

public class LibrarySourceTests
{
    [Fact]
    public void Folder_KeyRoundTrips()
    {
        Assert.Equal("folder", LibrarySource.Folder.Key);
        Assert.Equal(LibrarySource.Folder, LibrarySource.FromKey("folder"));
    }

    [Fact]
    public void Server_KeyRoundTrips()
    {
        var id = Guid.NewGuid();
        var source = LibrarySource.Server(id);

        Assert.Equal(id.ToString(), source.Key);
        Assert.Equal(source, LibrarySource.FromKey(id.ToString()));
    }

    [Fact]
    public void FromKey_RejectsGarbage()
    {
        Assert.Null(LibrarySource.FromKey("not-a-key"));
    }
}

public class LibraryTrackTests
{
    [Fact]
    public void Key_ForALocalFile_IsItsPath()
    {
        var track = new LibraryTrack
        {
            Id = new Uri("file:///Users/test/Music/song.flac"),
            Title = "Song",
            Artist = "Artist",
            AlbumArtist = "Artist",
            Album = "Album",
            HasLyrics = false
        };

        Assert.Equal("/Users/test/Music/song.flac", track.Key);
    }

    [Fact]
    public void Storable_ForARemoteUrl_KeepsOnlyTheIdParameter()
    {
        var url = new Uri("https://jellyfin.example.com/stream?id=abc123&api_key=SECRET");

        var storable = LibraryTrack.Storable(url);

        Assert.Contains("id=abc123", storable);
        Assert.DoesNotContain("SECRET", storable);
        Assert.DoesNotContain("api_key", storable);
    }

    [Fact]
    public void Storable_ForALocalFile_IsUnchanged()
    {
        var url = new Uri("file:///Users/test/Music/song.flac");
        Assert.Equal(url.AbsoluteUri, LibraryTrack.Storable(url));
    }
}
