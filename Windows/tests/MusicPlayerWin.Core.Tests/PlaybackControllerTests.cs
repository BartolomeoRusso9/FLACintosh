using MusicPlayerWin.Core.Audio;
using MusicPlayerWin.Core.History;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Playback;

namespace MusicPlayerWin.Core.Tests;

public sealed class PlaybackControllerTests
{
    [Fact]
    public async Task PlayThenNext_OpensAndStartsTheNextTrack()
    {
        var engine = new FakeAudioEngine();
        var root = Path.Combine(Path.GetTempPath(), "MusicPlayerWinTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        await using var controller = new PlaybackController(engine, history: new ListeningHistoryStore(root));
        var tracks = new[] { Track("A"), Track("B") };

        await controller.PlayAsync(tracks, 0);
        Assert.Equal("A", controller.CurrentTrack!.Title);
        Assert.True(engine.State.IsPlaying);

        await controller.NextAsync();
        Assert.Equal("B", controller.CurrentTrack!.Title);
        Assert.Equal(tracks[1].Url, engine.LastOpened);
        Directory.Delete(root, true);
    }

    private static LibraryTrack Track(string title) => new()
    {
        Id = new Uri($"file:///music/{title}.flac"),
        Title = title,
        Artist = "Artist",
        AlbumArtist = "Artist",
        Album = "Album",
        HasLyrics = false,
        Duration = 120
    };

    private sealed class FakeAudioEngine : IAudioEngine
    {
        public AudioState State { get; private set; } = new();
        public AudioFormatInfo? Format { get; private set; }
        public Uri? LastOpened { get; private set; }

        public event EventHandler? StateChanged;
        public event EventHandler? PlaybackEnded;
        public event EventHandler<AudioErrorEventArgs>? Error;

        public Task OpenAsync(Uri source, CancellationToken cancellationToken = default)
        {
            LastOpened = source;
            State = State with { Position = 0, Duration = 120 };
            StateChanged?.Invoke(this, EventArgs.Empty);
            return Task.CompletedTask;
        }

        public void Play() => State = State with { IsPlaying = true };
        public void Pause() => State = State with { IsPlaying = false };
        public void Stop() => State = State with { IsPlaying = false, Position = 0 };
        public void Seek(double seconds) => State = State with { Position = Math.Max(0, seconds) };
        public void SetVolume(double normalizedVolume) => State = State with { Volume = normalizedVolume };

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
