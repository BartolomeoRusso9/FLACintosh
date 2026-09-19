using MusicPlayerWin.Core.Audio;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.History;

namespace MusicPlayerWin.Core.Playback;

/// <summary>
/// Coordinates the queue with an injected audio engine. This is the Core
/// equivalent of the stateful part of FLACintosh PlaybackModel, without any
/// WinRT/UI dependencies.
/// </summary>
public sealed class PlaybackController : IAsyncDisposable
{
    private readonly IAudioEngine _audio;
    private readonly PlaybackQueue _queue;
    private readonly Func<LibraryTrack, CancellationToken, Task<Uri>> _sourceResolver;
    private readonly ListeningHistoryStore _history;
    private readonly Func<LibraryTrack, Uri, double>? _trackGainResolver;
    private AudioState _lastAudioState = new();
    private CancellationTokenSource? _prepareCts;
    private int? _preparedQueueIndex;
    private bool _disposed;

    public PlaybackController(
        IAudioEngine audio,
        Random? random = null,
        Func<LibraryTrack, CancellationToken, Task<Uri>>? sourceResolver = null,
        ListeningHistoryStore? history = null,
        Func<LibraryTrack, Uri, double>? trackGainResolver = null)
    {
        _audio = audio ?? throw new ArgumentNullException(nameof(audio));
        _sourceResolver = sourceResolver ?? ((track, _) => Task.FromResult(track.Url));
        _history = history ?? new ListeningHistoryStore();
        _trackGainResolver = trackGainResolver;
        _queue = new PlaybackQueue(random)
        {
            MoreToPlay = () => MoreToPlay?.Invoke() ?? Array.Empty<LibraryTrack>()
        };

        _audio.PlaybackEnded += OnPlaybackEnded;
        _audio.Error += OnAudioError;
        _audio.StateChanged += OnAudioStateChanged;
        _queue.Changed += OnQueueChanged;
        if (_audio is ITransitionAudioEngine transition)
            transition.TransitionCompleted += OnTransitionCompleted;
    }

    public PlaybackQueue Queue => _queue;
    public IAudioEngine Audio => _audio;
    public LibraryTrack? CurrentTrack => _queue.CurrentTrack;
    public string? LastError { get; private set; }
    public IReadOnlyList<LibraryTrack> UpNext => _queue.UpNext;

    /// <summary>Optional continuation supplied by the library (AutoPlay).</summary>
    public Func<IReadOnlyList<LibraryTrack>>? MoreToPlay { get; set; }

    public event EventHandler? TrackChanged;
    public event EventHandler? StateChanged;
    public event EventHandler<AudioErrorEventArgs>? Error;

    public async Task PlayAsync(
        IReadOnlyList<LibraryTrack> tracks,
        int startingAt,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (startingAt < 0 || startingAt >= tracks.Count)
            throw new ArgumentOutOfRangeException(nameof(startingAt));

        _history.Finish();
        _queue.Play(tracks, startingAt);
        var opened = await OpenCurrentAsync(cancellationToken).ConfigureAwait(false);
        ApplyTrackGain(CurrentTrack, opened);
        _audio.Play();
        LastError = null;
        if (CurrentTrack is { } current) _history.Start(current);
        TrackChanged?.Invoke(this, EventArgs.Empty);
        StateChanged?.Invoke(this, EventArgs.Empty);
        _ = PrepareFollowingAsync();
    }

    public async Task JumpAsync(int queueIndex, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (queueIndex < 0 || queueIndex >= _queue.Queue.Count)
            return;

        _history.Finish();
        _queue.Jump(queueIndex);
        var opened = await OpenCurrentAsync(cancellationToken).ConfigureAwait(false);
        ApplyTrackGain(CurrentTrack, opened);
        _audio.Play();
        LastError = null;
        if (CurrentTrack is { } current) _history.Start(current);
        TrackChanged?.Invoke(this, EventArgs.Empty);
        StateChanged?.Invoke(this, EventArgs.Empty);
        _ = PrepareFollowingAsync();
    }

    public async Task<bool> NextAsync(CancellationToken cancellationToken = default)
    {
        return await AdvanceAsync(+1, cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> PreviousAsync(CancellationToken cancellationToken = default)
    {
        // FLACintosh restarts a track when previous is requested after the
        // first few seconds; callers can opt into that UX before navigating.
        if (_audio.State.Position > 3)
        {
            _audio.Seek(0);
            return true;
        }

        return await AdvanceAsync(-1, cancellationToken).ConfigureAwait(false);
    }

    public void TogglePlayPause()
    {
        ThrowIfDisposed();
        if (_audio.State.IsPlaying)
            _audio.Pause();
        else
            _audio.Play();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Stop()
    {
        ThrowIfDisposed();
        _audio.Stop();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Seek(double seconds)
    {
        ThrowIfDisposed();
        _audio.Seek(Math.Max(0, seconds));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetVolume(double normalizedVolume)
    {
        ThrowIfDisposed();
        _audio.SetVolume(Math.Clamp(normalizedVolume, 0, 1));
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnTransitionCompleted(object? sender, EventArgs e)
    {
        if (_preparedQueueIndex is not int preparedIndex) return;
        if (_queue.CurrentIndex is not int current || _queue.FollowingIndex != preparedIndex)
        {
            _preparedQueueIndex = null;
            return;
        }

        _history.Finish();
        var result = _queue.Advance(+1);
        _preparedQueueIndex = null;
        if (result.Outcome != PlaybackAdvanceOutcome.Started) return;
        if (CurrentTrack is { } track) _history.Start(track);
        LastError = null;
        TrackChanged?.Invoke(this, EventArgs.Empty);
        StateChanged?.Invoke(this, EventArgs.Empty);
        _ = PrepareFollowingAsync();
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _audio.PlaybackEnded -= OnPlaybackEnded;
        _audio.Error -= OnAudioError;
        _audio.StateChanged -= OnAudioStateChanged;
        _queue.Changed -= OnQueueChanged;
        if (_audio is ITransitionAudioEngine transition)
            transition.TransitionCompleted -= OnTransitionCompleted;
        _prepareCts?.Cancel();
        _prepareCts?.Dispose();
        _history.Finish();
        await _audio.DisposeAsync().ConfigureAwait(false);
    }

    private async Task<bool> AdvanceAsync(int offset, CancellationToken cancellationToken)
    {
        _history.Finish();
        var result = _queue.Advance(offset);
        if (result.Outcome == PlaybackAdvanceOutcome.Stopped)
        {
            _audio.Stop();
            StateChanged?.Invoke(this, EventArgs.Empty);
            return false;
        }

        if (result.Outcome == PlaybackAdvanceOutcome.NoOp || result.Index is null)
            return false;

        var opened = await OpenCurrentAsync(cancellationToken).ConfigureAwait(false);
        ApplyTrackGain(CurrentTrack, opened);
        _audio.Play();
        LastError = null;
        if (CurrentTrack is { } current) _history.Start(current);
        TrackChanged?.Invoke(this, EventArgs.Empty);
        StateChanged?.Invoke(this, EventArgs.Empty);
        _ = PrepareFollowingAsync();
        return true;
    }

    private async Task<Uri> OpenCurrentAsync(CancellationToken cancellationToken)
    {
        var track = CurrentTrack ?? throw new InvalidOperationException("Playback has no current track.");
        var source = await _sourceResolver(track, cancellationToken).ConfigureAwait(false);
        await _audio.OpenAsync(source, cancellationToken).ConfigureAwait(false);
        return source;
    }

    public async Task PrepareFollowingAsync(CancellationToken cancellationToken = default)
    {
        if (_audio is not ITransitionAudioEngine transition) return;

        _prepareCts?.Cancel();
        _prepareCts?.Dispose();
        _prepareCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var ct = _prepareCts.Token;
        _preparedQueueIndex = null;
        transition.CancelPreparedNext();

        var index = _queue.FollowingIndex;
        if (index is null || _queue.Queue.Count == 0) return;
        if (index < 0 || index >= _queue.Queue.Count) return;
        var track = _queue.Queue[index.Value];

        try
        {
            var source = await _sourceResolver(track, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var gain = _trackGainResolver?.Invoke(track, source) ?? 0;
            await transition.PrepareNextAsync(source, gain, ct).ConfigureAwait(false);
            _preparedQueueIndex = index;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception ex)
        {
            LastError = ex.Message;
            Error?.Invoke(this, new AudioErrorEventArgs(ex));
        }
    }

    public async Task ReapplyCurrentGainAsync(CancellationToken cancellationToken = default)
    {
        if (CurrentTrack is not { } track) return;
        var source = await _sourceResolver(track, cancellationToken).ConfigureAwait(false);
        ApplyTrackGain(track, source);
        _ = PrepareFollowingAsync(cancellationToken);
    }

    private void ApplyTrackGain(LibraryTrack? track, Uri source)
    {
        if (_audio is not ITrackGainAudioEngine gainEngine || track is null) return;
        gainEngine.SetTrackGain(_trackGainResolver?.Invoke(track, source) ?? 0);
    }

    private async void OnPlaybackEnded(object? sender, EventArgs e)
    {
        try
        {
            await NextAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            OnAudioError(this, new AudioErrorEventArgs(ex));
        }
    }

    private void OnQueueChanged(object? sender, EventArgs e)
    {
        _preparedQueueIndex = null;
        StateChanged?.Invoke(this, EventArgs.Empty);
        _ = PrepareFollowingAsync();
    }

    private void OnAudioStateChanged(object? sender, EventArgs e)
    {
        var state = _audio.State;
        if (_lastAudioState.IsPlaying && state.IsPlaying)
        {
            var delta = state.Position - _lastAudioState.Position;
            _history.Accumulate(delta);
        }
        _lastAudioState = state;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnAudioError(object? sender, AudioErrorEventArgs args)
    {
        LastError = args.Exception.Message;
        Error?.Invoke(this, args);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(PlaybackController));
    }
}
