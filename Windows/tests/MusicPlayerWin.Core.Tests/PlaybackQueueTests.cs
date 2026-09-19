using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Playback;
using Xunit;

namespace MusicPlayerWin.Core.Tests;

public partial class PlaybackQueueTests
{
    private static LibraryTrack Track(string name) => new()
    {
        Id = new Uri($"file:///music/{name}.flac"),
        Title = name,
        Artist = "Test Artist",
        AlbumArtist = "Test Artist",
        Album = "Test Album",
        HasLyrics = false
    };

    private static List<LibraryTrack> Tracks(params string[] names) =>
        names.Select(Track).ToList();

    [Fact]
    public void Play_StartsAtRequestedIndex_EvenWithShuffleOn()
    {
        var queue = new PlaybackQueue(new Random(42)) { IsShuffling = true };
        queue.Play(Tracks("a", "b", "c", "d"), startingAt: 2);

        Assert.Equal(2, queue.CurrentIndex);
        // Whatever was asked for plays first, even shuffled: it must land at
        // position 0 of the play order, so there is nothing before it to
        // move back to.
        Assert.Equal(PlaybackAdvanceOutcome.Stopped, queue.Advance(-1).Outcome);
    }

    [Fact]
    public void Advance_MovesForwardAndBackward_ThenStopsAtTheEnd()
    {
        var queue = new PlaybackQueue();
        queue.Play(Tracks("a", "b", "c"), startingAt: 0);

        Assert.Equal(PlaybackAdvanceResult.Started(1), queue.Advance(1));
        Assert.Equal(1, queue.CurrentIndex);
        Assert.Equal(PlaybackAdvanceResult.Started(2), queue.Advance(1));
        Assert.Equal(PlaybackAdvanceOutcome.Stopped, queue.Advance(1).Outcome);
        // Off the end of the queue: stop where the music stopped.
        Assert.Equal(2, queue.CurrentIndex);
    }

    [Fact]
    public void RepeatAll_WrapsAtBothEnds()
    {
        var queue = new PlaybackQueue { RepeatMode = RepeatMode.All };
        queue.Play(Tracks("a", "b", "c"), startingAt: 0);

        queue.Jump(2);
        Assert.Equal(PlaybackAdvanceResult.Started(0), queue.Advance(1)); // wraps forward

        queue.Jump(0);
        Assert.Equal(PlaybackAdvanceResult.Started(2), queue.Advance(-1)); // wraps backward
    }

    [Fact]
    public void AutoPlay_OnlyContinuesForwardsOffTheEnd_NeverBackwardsOffTheFront()
    {
        var queue = new PlaybackQueue { AutoPlay = true };
        queue.Play(Tracks("a", "b"), startingAt: 0);

        var callCount = 0;
        queue.MoreToPlay = () =>
        {
            callCount++;
            return Tracks("x", "y");
        };

        // Previous, on the first track: must NOT pull in more tracks. A
        // random continuation answering "previous" would be startling.
        Assert.Equal(PlaybackAdvanceOutcome.Stopped, queue.Advance(-1).Outcome);
        Assert.Equal(0, callCount);

        // Next, off the end: DOES pull in more tracks.
        queue.Jump(1);
        var result = queue.Advance(1);
        Assert.Equal(PlaybackAdvanceResult.Started(0), result);
        Assert.Equal(1, callCount);
        Assert.Equal(2, queue.Queue.Count);
        Assert.Equal("x", queue.Queue[0].Title);
    }

    [Fact]
    public void ShuffleToggledMidPlay_MovesCurrentTrackToFrontOfNewOrder()
    {
        var queue = new PlaybackQueue(new Random(7));
        queue.Play(Tracks("a", "b", "c", "d", "e"), startingAt: 0);
        queue.Jump(3);

        queue.IsShuffling = true;

        Assert.Equal(3, queue.CurrentIndex);
        Assert.DoesNotContain(3, queue.UpNextIndices);
        // At the front of the new order: nothing to go back to.
        Assert.Equal(PlaybackAdvanceOutcome.Stopped, queue.Advance(-1).Outcome);
    }

    [Fact]
    public void ClearQueue_TruncatesToTheCurrentTrackOnly()
    {
        var queue = new PlaybackQueue();
        queue.Play(Tracks("a", "b", "c"), startingAt: 1);

        queue.ClearQueue();

        Assert.Single(queue.Queue);
        Assert.Equal("b", queue.Queue[0].Title);
        Assert.Equal(0, queue.CurrentIndex);
        Assert.Empty(queue.UpNextIndices);
    }

    [Fact]
    public void Jump_DoesNotReshuffleTheExistingOrder()
    {
        var queue = new PlaybackQueue(new Random(3)) { IsShuffling = true };
        queue.Play(Tracks("a", "b", "c", "d"), startingAt: 0);

        var fullOrderBefore = new[] { queue.CurrentIndex!.Value }.Concat(queue.UpNextIndices).ToList();

        // Jump around, then back to the original current index.
        queue.Jump(fullOrderBefore[1]);
        queue.Jump(fullOrderBefore[0]);

        var fullOrderAfter = new[] { queue.CurrentIndex!.Value }.Concat(queue.UpNextIndices).ToList();

        Assert.Equal(fullOrderBefore, fullOrderAfter);
    }
}

namespace MusicPlayerWin.Core.Tests;

public partial class PlaybackQueueTests
{
    [Fact]
    public void Move_ReordersWithoutChangingCurrentTrack()
    {
        var queue = new PlaybackQueue();
        queue.Play(Tracks("a", "b", "c"), 0);

        Assert.True(queue.Move(2, 1));
        Assert.Equal("a", queue.CurrentTrack!.Title);
        Assert.Equal(["a", "c", "b"], queue.Queue.Select(x => x.Title).ToArray());
    }

    [Fact]
    public void RemoveNext_RejectsCurrentTrack()
    {
        var queue = new PlaybackQueue();
        queue.Play(Tracks("a", "b"), 0);
        Assert.False(queue.RemoveNext(0));
        Assert.Equal(2, queue.Queue.Count);
    }
}
