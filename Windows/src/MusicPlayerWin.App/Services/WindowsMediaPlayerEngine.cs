using MusicPlayerWin.Core.Audio;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace MusicPlayerWin.App.Services;

public enum MediaRemoteCommand
{
    Play,
    Pause,
    Next,
    Previous,
    Stop
}

public sealed class MediaRemoteCommandEventArgs(MediaRemoteCommand command) : EventArgs
{
    public MediaRemoteCommand Command { get; } = command;
}

/// <summary>
/// Windows implementation of the Core audio contract, using the system
/// MediaPlayer/MediaSource stack. It deliberately stays behind IAudioEngine.
/// SMTC is handled here and translated into Core playback commands by AppServices.
/// </summary>
public sealed class WindowsMediaPlayerEngine : IAudioEngine
{
    private readonly MediaPlayer _player = new();
    private readonly SystemMediaTransportControls _smtc;
    private AudioState _state = new();
    private bool _disposed;

    public AudioState State => _state;
    public AudioFormatInfo? Format { get; private set; }

    public event EventHandler? StateChanged;
    public event EventHandler? PlaybackEnded;
    public event EventHandler<AudioErrorEventArgs>? Error;
    public event EventHandler<MediaRemoteCommandEventArgs>? RemoteCommand;

    public WindowsMediaPlayerEngine()
    {
        _player.MediaEnded += PlayerOnMediaEnded;
        _player.MediaFailed += PlayerOnMediaFailed;
        _player.PlaybackSession.PlaybackStateChanged += PlaybackSessionOnPlaybackStateChanged;
        _player.PlaybackSession.PositionChanged += PlaybackSessionOnPositionChanged;
        _smtc = _player.SystemMediaTransportControls;

        // The app owns the queue, so Windows must not try to advance the
        // MediaPlayer itself. We translate SMTC buttons back into the same
        // controller used by the WinUI controls.
        _player.CommandManager.IsEnabled = false;
        _smtc.IsPlayEnabled = true;
        _smtc.IsPauseEnabled = true;
        _smtc.IsNextEnabled = true;
        _smtc.IsPreviousEnabled = true;
        _smtc.IsStopEnabled = true;
        _smtc.ButtonPressed += SmtcOnButtonPressed;
        _player.Volume = 1;
    }

    public Task OpenAsync(Uri source, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        cancellationToken.ThrowIfCancellationRequested();

        _player.Pause();
        _player.Source = MediaSource.CreateFromUri(source);
        UpdateState(position: 0);
        return Task.CompletedTask;
    }

    public void UpdateNowPlaying(string? title, string? artist, string? album)
    {
        if (_disposed) return;
        if (string.IsNullOrWhiteSpace(title))
        {
            _smtc.DisplayUpdater.ClearAll();
            _smtc.PlaybackStatus = MediaPlaybackStatus.Stopped;
            _smtc.DisplayUpdater.Update();
            return;
        }

        var updater = _smtc.DisplayUpdater;
        updater.Type = MediaPlaybackType.Music;
        updater.AppMediaId = "MusicPlayerWin";
        updater.MusicProperties.Title = title;
        updater.MusicProperties.Artist = artist ?? string.Empty;
        updater.MusicProperties.AlbumTitle = album ?? string.Empty;
        updater.Update();
        UpdateSmtcState(_state);
    }

    public void Play()
    {
        ThrowIfDisposed();
        _player.Play();
        UpdateState();
    }

    public void Pause()
    {
        ThrowIfDisposed();
        _player.Pause();
        UpdateState();
    }

    public void Stop()
    {
        ThrowIfDisposed();
        _player.Pause();
        _player.PlaybackSession.Position = TimeSpan.Zero;
        UpdateState(position: 0, isPlaying: false);
    }

    public void Seek(double seconds)
    {
        ThrowIfDisposed();
        var duration = _player.PlaybackSession.NaturalDuration.TotalSeconds;
        var target = duration > 0 ? Math.Clamp(seconds, 0, duration) : Math.Max(0, seconds);
        _player.PlaybackSession.Position = TimeSpan.FromSeconds(target);
        UpdateState(position: target);
    }

    public void SetVolume(double normalizedVolume)
    {
        ThrowIfDisposed();
        _player.Volume = Math.Clamp(normalizedVolume, 0, 1);
        UpdateState();
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        _player.MediaEnded -= PlayerOnMediaEnded;
        _player.MediaFailed -= PlayerOnMediaFailed;
        _player.PlaybackSession.PlaybackStateChanged -= PlaybackSessionOnPlaybackStateChanged;
        _player.PlaybackSession.PositionChanged -= PlaybackSessionOnPositionChanged;
        _smtc.ButtonPressed -= SmtcOnButtonPressed;
        _player.Dispose();
        return ValueTask.CompletedTask;
    }

    private void SmtcOnButtonPressed(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs args)
    {
        var command = args.Button switch
        {
            SystemMediaTransportControlsButton.Play => MediaRemoteCommand.Play,
            SystemMediaTransportControlsButton.Pause => MediaRemoteCommand.Pause,
            SystemMediaTransportControlsButton.Next => MediaRemoteCommand.Next,
            SystemMediaTransportControlsButton.Previous => MediaRemoteCommand.Previous,
            SystemMediaTransportControlsButton.Stop => MediaRemoteCommand.Stop,
            _ => (MediaRemoteCommand?)null
        };
        if (command is { } value)
            RemoteCommand?.Invoke(this, new MediaRemoteCommandEventArgs(value));
    }

    private void PlayerOnMediaEnded(MediaPlayer sender, object args)
    {
        UpdateState(isPlaying: false);
        PlaybackEnded?.Invoke(this, EventArgs.Empty);
    }

    private void PlayerOnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        var message = string.IsNullOrWhiteSpace(args.ErrorMessage)
            ? $"Windows MediaPlayer failed with error 0x{args.ExtendedErrorCode:X8}."
            : args.ErrorMessage;
        var exception = new InvalidOperationException(message);
        Error?.Invoke(this, new AudioErrorEventArgs(exception));
        UpdateState(isPlaying: false);
    }

    private void PlaybackSessionOnPlaybackStateChanged(MediaPlaybackSession sender, object args) => UpdateState();

    private void PlaybackSessionOnPositionChanged(MediaPlaybackSession sender, object args) => UpdateState();

    private void UpdateState(bool? isPlaying = null, double? position = null)
    {
        var session = _player.PlaybackSession;
        var duration = session.NaturalDuration.TotalSeconds;
        var currentPosition = position ?? session.Position.TotalSeconds;
        var playing = isPlaying ?? session.PlaybackState == MediaPlaybackState.Playing;
        var buffering = session.PlaybackState == MediaPlaybackState.Buffering;

        _state = new AudioState(
            IsPlaying: playing,
            IsBuffering: buffering,
            Position: Math.Max(0, currentPosition),
            Duration: Math.Max(0, duration),
            Volume: _player.Volume);
        UpdateSmtcState(_state);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void UpdateSmtcState(AudioState state)
    {
        if (_disposed) return;
        _smtc.PlaybackStatus = state.IsPlaying
            ? MediaPlaybackStatus.Playing
            : state.Position > 0 || state.Duration > 0
                ? MediaPlaybackStatus.Paused
                : MediaPlaybackStatus.Stopped;

        try
        {
            _smtc.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
            {
                StartTime = TimeSpan.Zero,
                EndTime = TimeSpan.FromSeconds(Math.Max(0, state.Duration)),
                Position = TimeSpan.FromSeconds(Math.Clamp(state.Position, 0, Math.Max(0, state.Duration))),
                MinSeekTime = TimeSpan.Zero,
                MaxSeekTime = TimeSpan.FromSeconds(Math.Max(0, state.Duration))
            });
        }
        catch
        {
            // Timeline metadata is optional; playback itself must not depend on it.
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(WindowsMediaPlayerEngine));
    }
}
