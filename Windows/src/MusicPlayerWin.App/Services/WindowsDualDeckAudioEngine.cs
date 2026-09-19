using MusicPlayerWin.Core.Audio;
using Windows.Media;
using Windows.Media.Playback;

namespace MusicPlayerWin.App.Services;

/// <summary>
/// Two-deck coordinator around the AudioGraph backend. Each deck owns a
/// completely independent graph/output path; the coordinator changes their
/// gains so two decoded files can overlap during a crossfade.
///
/// Gapless handoff is implemented as an immediate prepared-deck start when
/// the active source reaches MediaSourceCompleted. Windows' public MediaSource
/// API does not expose sample-accurate scheduling across two input nodes, so
/// this is intentionally documented as near-gapless rather than promising a
/// sample-perfect boundary.
/// </summary>
public sealed class WindowsDualDeckAudioEngine : IAudioEngine, IAudioEffectsEngine, ITrackGainAudioEngine, ITransitionAudioEngine
{
    private readonly object _gate = new();
    private readonly WindowsAudioGraphEngine _deckA;
    private readonly WindowsAudioGraphEngine _deckB;
    private readonly Timer _transitionTimer;
    private WindowsAudioGraphEngine _active;
    private WindowsAudioGraphEngine _standby;
    private AudioEffectsSettings _effects = AudioEffectsSettings.Default;
    private AudioState _state = new();
    private double _masterVolume = 1;
    private double _activeTrackGainDb;
    private bool _gapless = true;
    private bool _crossfade;
    private double _crossfadeSeconds = 6;
    private bool _prepared;
    private bool _transitioning;
    private DateTimeOffset _transitionStarted;
    private double _transitionDuration;
    private bool _disposed;
    private string? _nowTitle;
    private string? _nowArtist;
    private string? _nowAlbum;

    public WindowsDualDeckAudioEngine()
    {
        _deckA = new WindowsAudioGraphEngine(enableSystemControls: true);
        _deckB = new WindowsAudioGraphEngine(enableSystemControls: false);
        _active = _deckA;
        _standby = _deckB;

        _deckA.RemoteCommand += DeckAOnRemoteCommand;
        _deckA.Error += DeckOnError;
        _deckB.Error += DeckOnError;
        _deckA.PlaybackEnded += ActiveDeckOnPlaybackEnded;
        _deckB.PlaybackEnded += ActiveDeckOnPlaybackEnded;

        _transitionTimer = new Timer(PollTransition, null, 0, 20);
    }

    public AudioState State => _state;
    public AudioFormatInfo? Format => _active.Format;
    public double TrackGainDb => _activeTrackGainDb;
    public bool IsTransitioning => _transitioning;
    public bool HasPreparedNext => _prepared;

    public event EventHandler? StateChanged;
    public event EventHandler? PlaybackEnded;
    public event EventHandler<AudioErrorEventArgs>? Error;
    public event EventHandler<MediaRemoteCommandEventArgs>? RemoteCommand;
    public event EventHandler? TransitionCompleted;

    public void ConfigureTransition(bool gapless, bool crossfade, double crossfadeSeconds)
    {
        lock (_gate)
        {
            _gapless = gapless;
            _crossfade = crossfade;
            _crossfadeSeconds = Math.Clamp(crossfadeSeconds, 0, 12);
            if (!_crossfade && _transitioning)
                CancelTransitionLocked();
        }
        if (!_crossfade && !gapless)
            CancelPreparedNext();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task OpenAsync(Uri source, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        CancelPreparedNext();
        _active.Stop();
        await _active.OpenAsync(source, cancellationToken).ConfigureAwait(false);
        _active.SetTrackGain(_activeTrackGainDb);
        _active.SetVolume(_masterVolume);
        lock (_gate)
        {
            _state = new AudioState(false, false, 0, _active.State.Duration, _masterVolume);
            _transitioning = false;
        }
        UpdateNowPlaying(_nowTitle, _nowArtist, _nowAlbum);
        UpdateSystemTransportState();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ApplyEffects(AudioEffectsSettings settings)
    {
        _effects = settings.Normalize();
        _deckA.ApplyEffects(_effects);
        _deckB.ApplyEffects(_effects);
        ConfigureTransition(_effects.Gapless, _effects.Crossfade, _effects.CrossfadeSeconds);
    }

    public void SetTrackGain(double gainDb)
    {
        var value = Math.Clamp(double.IsFinite(gainDb) ? gainDb : 0, -96, 24);
        lock (_gate) _activeTrackGainDb = value;
        _active.SetTrackGain(value);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task PrepareNextAsync(Uri source, double trackGainDb, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        cancellationToken.ThrowIfCancellationRequested();

        CancelPreparedNext();
        try
        {
            await _standby.OpenAsync(source, cancellationToken).ConfigureAwait(false);
            _standby.ApplyEffects(_effects);
            _standby.SetTrackGain(Math.Clamp(trackGainDb, -96, 24));
            _standby.SetVolume(0);
            _standby.Stop();
            lock (_gate) _prepared = true;
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            CancelPreparedNext();
            throw;
        }
    }

    public void CancelPreparedNext()
    {
        lock (_gate)
        {
            if (_transitioning)
                CancelTransitionLocked();
            _prepared = false;
        }

        try { _standby.Stop(); } catch { }
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Play()
    {
        try
        {
            _active.SetVolume(_masterVolume);
            _active.Play();
            lock (_gate) _state = _active.State with { Volume = _masterVolume, IsPlaying = true };
            UpdateSystemTransportState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Pause()
    {
        try
        {
            _active.Pause();
            lock (_gate) _state = _active.State with { Volume = _masterVolume, IsPlaying = false };
            if (_transitioning) CancelTransitionLocked();
            UpdateSystemTransportState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Stop()
    {
        try
        {
            CancelPreparedNext();
            _active.Stop();
            lock (_gate) _state = _active.State with { Volume = _masterVolume, IsPlaying = false, Position = 0 };
            UpdateSystemTransportState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Seek(double seconds)
    {
        try
        {
            _active.Seek(seconds);
            lock (_gate) _state = _active.State with { Volume = _masterVolume };
            UpdateSystemTransportState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void SetVolume(double normalizedVolume)
    {
        try
        {
            _masterVolume = Math.Clamp(normalizedVolume, 0, 1);
            lock (_gate)
            {
                if (_transitioning)
                {
                    // The timer will re-apply the two relative levels.
                }
                else
                {
                    _active.SetVolume(_masterVolume);
                }
                _state = _state with { Volume = _masterVolume };
            }
            UpdateSystemTransportState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void UpdateNowPlaying(string? title, string? artist, string? album)
    {
        _nowTitle = title;
        _nowArtist = artist;
        _nowAlbum = album;
        _deckA.UpdateNowPlaying(title, artist, album);
    }

    public Task UpdateNowPlayingArtworkAsync(byte[]? artwork, CancellationToken cancellationToken = default) =>
        _deckA.UpdateNowPlayingArtworkAsync(artwork, cancellationToken);

    private void UpdateSystemTransportState()
    {
        try { _deckA.UpdateSystemTransportState(_state); } catch { }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _transitionTimer.Dispose();
        _deckA.RemoteCommand -= DeckAOnRemoteCommand;
        _deckA.Error -= DeckOnError;
        _deckB.Error -= DeckOnError;
        _deckA.PlaybackEnded -= ActiveDeckOnPlaybackEnded;
        _deckB.PlaybackEnded -= ActiveDeckOnPlaybackEnded;
        await _deckA.DisposeAsync().ConfigureAwait(false);
        await _deckB.DisposeAsync().ConfigureAwait(false);
    }

    private void ActiveDeckOnPlaybackEnded(object? sender, EventArgs e)
    {
        if (sender is not WindowsAudioGraphEngine deck) return;

        lock (_gate)
        {
            if (deck != _active) return;
            if (_prepared && _gapless && !_crossfade)
            {
                try
                {
                    _standby.SetVolume(_masterVolume);
                    _standby.Play();
                    var old = _active;
                    _active = _standby;
                    _standby = old;
                    _prepared = false;
                    _state = _active.State with { Volume = _masterVolume, IsPlaying = true };
                    _activeTrackGainDb = _active.TrackGainDb;
                    _standby.SetVolume(0);
                }
                catch (Exception ex)
                {
                    RaiseError(ex);
                    PlaybackEnded?.Invoke(this, EventArgs.Empty);
                    return;
                }
            }
            else
            {
                PlaybackEnded?.Invoke(this, EventArgs.Empty);
                return;
            }
        }

        UpdateSystemTransportState();
        StateChanged?.Invoke(this, EventArgs.Empty);
        TransitionCompleted?.Invoke(this, EventArgs.Empty);
        UpdateNowPlaying(_nowTitle, _nowArtist, _nowAlbum);
    }

    private void PollTransition(object? state)
    {
        if (_disposed) return;

        try
        {
            bool complete = false;
            lock (_gate)
            {
                if (_active.State.IsPlaying && _prepared && _crossfade && !_transitioning)
                {
                    var remaining = _active.State.Duration - _active.State.Position;
                    if (remaining > 0 && remaining <= Math.Max(0.25, _crossfadeSeconds))
                    {
                        _transitioning = true;
                        _transitionStarted = DateTimeOffset.UtcNow;
                        _transitionDuration = Math.Clamp(Math.Min(remaining, _crossfadeSeconds), 0.25, 12);
                        _standby.SetVolume(0);
                        _standby.Play();
                    }
                }

                if (_transitioning)
                {
                    var elapsed = (DateTimeOffset.UtcNow - _transitionStarted).TotalSeconds;
                    var progress = Math.Clamp(elapsed / Math.Max(0.001, _transitionDuration), 0, 1);
                    _active.SetVolume(_masterVolume * (1 - progress));
                    _standby.SetVolume(_masterVolume * progress);
                    complete = progress >= 1;
                    if (complete)
                    {
                        var old = _active;
                        _active = _standby;
                        _standby = old;
                        _prepared = false;
                        _transitioning = false;
                        _activeTrackGainDb = _active.TrackGainDb;
                        _standby.Stop();
                        _standby.SetVolume(0);
                        _state = _active.State with { Volume = _masterVolume, IsPlaying = true };
                    }
                }

                _state = _active.State with { Volume = _masterVolume };
            }

            if (complete)
            {
                UpdateSystemTransportState();
                UpdateNowPlaying(_nowTitle, _nowArtist, _nowAlbum);
                TransitionCompleted?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                UpdateSystemTransportState();
            }
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    private void CancelTransitionLocked()
    {
        if (!_transitioning) return;
        try { _active.SetVolume(_masterVolume); } catch { }
        try { _standby.Stop(); } catch { }
        _transitioning = false;
    }

    private void DeckAOnRemoteCommand(object? sender, MediaRemoteCommandEventArgs args) => RemoteCommand?.Invoke(this, args);

    private void DeckOnError(object? sender, AudioErrorEventArgs args) => Error?.Invoke(this, args);

    private void RaiseError(Exception ex) => Error?.Invoke(this, new AudioErrorEventArgs(ex));

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(WindowsDualDeckAudioEngine));
    }
}
