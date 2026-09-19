using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Playlists;
using MusicPlayerWin.Core.Servers;

namespace MusicPlayerWin.Core.Tests;

public sealed class PersistenceTests
{
    [Fact]
    public void FingerprintIgnoresNonIdentityQueryParameters()
    {
        var first = new Uri("https://example.test/stream?id=42&token=one");
        var second = new Uri("https://example.test/stream?id=42&token=two");
        Assert.Equal(RemoteCache.Fingerprint(first), RemoteCache.Fingerprint(second));
    }

    [Fact]
    public void StorableServerUrlKeepsTrackIdOnly()
    {
        var source = new Uri("https://example.test/audio?id=42&api_key=secret&t=nonce");
        var stored = LibraryTrack.Storable(source);
        Assert.Contains("id=42", stored, StringComparison.Ordinal);
        Assert.DoesNotContain("secret", stored, StringComparison.Ordinal);
        Assert.DoesNotContain("nonce", stored, StringComparison.Ordinal);
    }

    [Fact]
    public void PlaylistRoundTripsThroughDisk()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new PlaylistStore(root);
            var playlist = store.Create("Favourites");
            store.Rename(playlist.Id, "Favorites");

            var reloaded = new PlaylistStore(root);
            Assert.Single(reloaded.Playlists);
            Assert.Equal("Favorites", reloaded.Playlists[0].Name);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void ServerStoreRoundTripsWithoutPasswords()
    {
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var store = new MusicServerStore(root);
            store.Add(new MusicServer { Name = "Jellyfin", Kind = MusicServerKind.Jellyfin, Address = new Uri("https://example.test"), Username = "bart" });
            var reloaded = new MusicServerStore(root);
            Assert.Single(reloaded.Servers);
            Assert.Equal("bart", reloaded.Servers[0].Username);
        }
        finally { Directory.Delete(root, true); }
    }
}
