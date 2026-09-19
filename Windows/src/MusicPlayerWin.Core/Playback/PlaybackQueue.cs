using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.Core.Playback;

public enum RepeatMode
{
    Off,
    All,
    One
}

public static class RepeatModeExtensions
{
    /// <summary>Cycles Off → All → One → Off, matching the transport button.</summary>
    public static RepeatMode Next(this RepeatMode mode) => mode switch
    {
        RepeatMode.Off => RepeatMode.All,
        RepeatMode.All => RepeatMode.One,
        RepeatMode.One => RepeatMode.Off,
        _ => RepeatMode.Off
    };
}

public enum PlaybackAdvanceOutcome
{
    /// <summary>Nothing to do — there was no current track to advance from.</summary>
    NoOp,

    /// <summary>A new index was picked; the caller should start playing it.</summary>
    Started,

    /// <summary>
    /// Ran off the end (or start) of the queue with nowhere to go — the
    /// caller should stop playback where it is, not restart the record.
    /// </summary>
    Stopped
}

public readonly record struct PlaybackAdvanceResult(PlaybackAdvanceOutcome Outcome, int? Index = null)
{
    public static readonly PlaybackAdvanceResult NoOp = new(PlaybackAdvanceOutcome.NoOp);
    public static readonly PlaybackAdvanceResult Stopped = new(PlaybackAdvanceOutcome.Stopped);
    public static PlaybackAdvanceResult Started(int index) => new(PlaybackAdvanceOutcome.Started, index);
}

/// <summary>
/// What is lined up, in the order it was handed over, plus the shuffled or
/// unshuffled play order and the navigation rules — advance, repeat, the
/// auto-play continuation.
///
/// Ported from the queue half of <c>PlaybackModel.swift</c>. The audio-engine
/// half (decks, crossfade, actually making sound) is deliberately not here:
/// this class only ever decides *which* index plays next. Something else —
/// the future AudioEngine/coordinator in the App project — acts on that
/// decision. <c>CancelFade()</c>, <c>RefreshGapless()</c> and similar
/// engine-side calls the original makes inline are the caller's job now, not
/// this class's.
///
/// Shuffling takes an injectable <see cref="Random"/> so tests can be
/// deterministic; production code that doesn't pass one gets
/// <see cref="Random.Shared"/>, i.e. genuinely random, same as the original.
/// </summary>
public sealed class PlaybackQueue
{
    private readonly Random _random;
    private List<LibraryTrack> _queue = new();
    private List<int> _order = new();

    public PlaybackQueue(Random? random = null)
    {
        _random = random ?? Random.Shared;
    }

    public IReadOnlyList<LibraryTrack> Queue => _queue;

    public event EventHandler? Changed;

    public int? CurrentIndex { get; private set; }

    private bool _isShuffling;

    public bool IsShuffling
    {
        get => _isShuffling;
        set
        {
            if (_isShuffling == value) return;
            _isShuffling = value;
            RebuildOrder();
            // Turned on mid-record, the song playing goes to the front of the
            // new order. Left wherever the shuffle put it, everything
            // shuffled in ahead of it would never play, and a queue of forty
            // could end after three.
            if (_isShuffling && CurrentIndex is int current)
            {
                var position = _order.IndexOf(current);
                if (position >= 0) Swap(0, position);
            }
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private RepeatMode _repeatMode = RepeatMode.Off;
    public RepeatMode RepeatMode
    {
        get => _repeatMode;
        set
        {
            if (_repeatMode == value) return;
            _repeatMode = value;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Keep going when the queue runs out, instead of stopping.</summary>
    public bool AutoPlay { get; set; }

    /// <summary>
    /// Where that continuation comes from — the library, which is the only
    /// thing that knows what else there is to play.
    /// </summary>
    public Func<IReadOnlyList<LibraryTrack>>? MoreToPlay { get; set; }

    public LibraryTrack? CurrentTrack =>
        CurrentIndex is int index && index >= 0 && index < _queue.Count ? _queue[index] : null;

    /// <summary>
    /// Positions in <see cref="Queue"/> still ahead, in playing order —
    /// shuffled when shuffle is on, which is the order the list has to show.
    /// </summary>
    public IReadOnlyList<int> UpNextIndices
    {
        get
        {
            if (CurrentIndex is not int current) return Array.Empty<int>();
            var position = _order.IndexOf(current);
            if (position < 0) return Array.Empty<int>();
            return _order.Skip(position + 1).Where(i => i >= 0 && i < _queue.Count).ToList();
        }
    }

    /// <summary>
    /// What is still ahead, in playing order — the part of the queue the list
    /// shows and "Clear" throws away.
    /// </summary>
    public IReadOnlyList<LibraryTrack> UpNext => UpNextIndices.Select(i => _queue[i]).ToList();

    /// <summary>
    /// The record after this one, if the queue has one to give — used to
    /// decide whether a crossfade has somewhere to go.
    /// </summary>
    public int? FollowingIndex
    {
        get
        {
            if (CurrentIndex is not int current) return null;
            var position = _order.IndexOf(current);
            if (position < 0) return null;
            if (position + 1 < _order.Count) return _order[position + 1];
            return RepeatMode == RepeatMode.All && _order.Count > 0 ? _order[0] : null;
        }
    }

    public void Play(IReadOnlyList<LibraryTrack> tracks, int startingAt)
    {
        _queue = tracks.ToList();
        RebuildOrder();
        // Whatever was asked for plays first, even with shuffle on — the
        // alternative is clicking a song and hearing a different one.
        var position = _order.IndexOf(startingAt);
        if (position >= 0) Swap(0, position);
        Start(startingAt);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Moves by <paramref name="offset"/> positions in the current play
    /// order (+1 next, -1 previous). Returns what the caller should do about
    /// it — see <see cref="PlaybackAdvanceOutcome"/>.
    /// </summary>
    public PlaybackAdvanceResult Advance(int offset)
    {
        if (CurrentIndex is not int current) return PlaybackAdvanceResult.NoOp;
        var position = _order.IndexOf(current);
        if (position < 0) return PlaybackAdvanceResult.NoOp;

        var next = position + offset;
        if (next >= 0 && next < _order.Count)
        {
            Start(_order[next]);
            Changed?.Invoke(this, EventArgs.Empty);
            return PlaybackAdvanceResult.Started(_order[next]);
        }

        if (RepeatMode == RepeatMode.All && _order.Count > 0)
        {
            var wrapped = offset > 0 ? _order[0] : _order[^1];
            Start(wrapped);
            Changed?.Invoke(this, EventArgs.Empty);
            return PlaybackAdvanceResult.Started(wrapped);
        }

        // Forwards only: running off the *front* of the queue is someone
        // pressing previous on the first track, and answering that with a
        // random record would be startling.
        if (offset > 0 && AutoPlay && MoreToPlay?.Invoke() is { Count: > 0 } more)
        {
            Play(more, 0);
            return PlaybackAdvanceResult.Started(0);
        }

        // Off the end of the queue: stop where the music stopped rather than
        // silently restarting the record.
        return PlaybackAdvanceResult.Stopped;
    }

    /// <summary>
    /// Plays a track that is already queued, keeping the order as it is.
    /// Handing the queue to <see cref="Play"/> again would reshuffle it.
    /// </summary>
    public void Jump(int index) { Start(index); Changed?.Invoke(this, EventArgs.Empty); }

    /// <summary>
    /// Drops everything after the current track. The record on now keeps
    /// playing: "clear" is about the list of what comes next, not about the
    /// needle.
    /// </summary>

    public bool Move(int oldIndex, int newIndex)
    {
        if (oldIndex < 0 || oldIndex >= _queue.Count || newIndex < 0 || newIndex >= _queue.Count || oldIndex == newIndex) return false;
        var currentTrack = CurrentIndex is int ci && ci >= 0 && ci < _queue.Count ? _queue[ci] : null;
        var item = _queue[oldIndex];
        _queue.RemoveAt(oldIndex);
        _queue.Insert(newIndex, item);
        var newCurrent = currentTrack is null ? (int?)null : _queue.FindIndex(t => string.Equals(t.Key, currentTrack.Key, StringComparison.OrdinalIgnoreCase));
        CurrentIndex = newCurrent;
        RebuildOrder();
        if (currentTrack is not null && CurrentIndex is int current)
        {
            var pos = _order.IndexOf(current);
            if (pos > 0) Swap(0, pos);
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void ClearAfterCurrent()
    {
        if (CurrentIndex is not int current || current < 0 || current >= _queue.Count) { ClearQueue(); return; }
        var currentTrack = _queue[current];
        var position = _order.IndexOf(current);
        var keep = _order.Take(position + 1).ToHashSet();
        _queue = _queue.Where((_, i) => keep.Contains(i)).ToList();
        RebuildOrder();
        CurrentIndex = _queue.FindIndex(t => string.Equals(t.Key, currentTrack.Key, StringComparison.OrdinalIgnoreCase));
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Enqueue(IEnumerable<LibraryTrack> tracks, bool playIfEmpty = false)
    {
        var incoming = tracks.Where(t => t is not null).ToList();
        if (incoming.Count == 0) return;
        var wasEmpty = _queue.Count == 0;
        _queue.AddRange(incoming);
        RebuildOrder();
        if (playIfEmpty && wasEmpty) CurrentIndex = 0;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public IReadOnlyList<LibraryTrack> Snapshot() => _queue.ToArray();

    /// <summary>Removes a non-current track from the queue without disturbing what is playing.</summary>
    public bool RemoveNext(int queueIndex)
    {
        if (queueIndex < 0 || queueIndex >= _queue.Count || CurrentIndex == queueIndex) return false;
        _queue.RemoveAt(queueIndex);
        _order = _order
            .Where(i => i != queueIndex)
            .Select(i => i > queueIndex ? i - 1 : i)
            .ToList();
        if (CurrentIndex is int current && current > queueIndex) CurrentIndex = current - 1;
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void ClearQueue()
    {
        if (CurrentIndex is not int current || current < 0 || current >= _queue.Count)
        {
            _queue = new List<LibraryTrack>();
            _order = new List<int>();
            CurrentIndex = null;
            Changed?.Invoke(this, EventArgs.Empty);
            return;
        }

        var track = _queue[current];
        _queue = new List<LibraryTrack> { track };
        CurrentIndex = 0;
        RebuildOrder();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Start(int index)
    {
        if (index < 0 || index >= _queue.Count) return;
        CurrentIndex = index;
    }

    private void RebuildOrder()
    {
        _order = Enumerable.Range(0, _queue.Count).ToList();
        if (IsShuffling) Shuffle(_order);
    }

    private void Shuffle(List<int> list)
    {
        // Fisher-Yates, driven by the injectable Random.
        for (var i = list.Count - 1; i > 0; i--)
        {
            var j = _random.Next(i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }
    }

    private void Swap(int a, int b) => (_order[a], _order[b]) = (_order[b], _order[a]);
}
