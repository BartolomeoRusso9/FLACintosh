using System.Threading;
using System.Runtime.InteropServices.WindowsRuntime;
using MusicPlayerWin.Core.Audio;
using Windows.Media;
using Windows.Media.Audio;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Streams;
using System.Security.Cryptography;

namespace MusicPlayerWin.App.Services;

/// <summary>
/// Windows playback backend using AudioGraph instead of MediaPlayer's output
/// path. MediaSourceAudioInputNode gives us decoded media inside a graph,
/// which lets the app attach Windows' platform equalizer effect to the output.
/// </summary>
public sealed class WindowsAudioGraphEngine : IAudioEngine, IAudioEffectsEngine, ITrackGainAudioEngine
{
    private readonly object _gate = new();
    private readonly MediaPlayer _transport = new();
    private readonly SystemMediaTransportControls _smtc;
    private readonly Timer _pollTimer;

    private AudioGraph? _graph;
    private AudioDeviceOutputNode? _output;
    private MediaSourceAudioInputNode? _input;
    private MediaSource? _source;
    private EqualizerEffectDefinition? _equalizer;
    private AudioEffectsSettings _effects = AudioEffectsSettings.Default;
    private double _trackGainDb;
    private readonly bool _systemControlsEnabled;
    private AudioState _state = new();
    private bool _disposed;
    private readonly string _smtcArtworkFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MusicPlayerWin", "SMTCArtwork");

    public WindowsAudioGraphEngine(bool enableSystemControls = true)
    {
        _systemControlsEnabled = enableSystemControls;
        _smtc = _transport.SystemMediaTransportControls;
        _transport.CommandManager.IsEnabled = false;
        _smtc.IsPlayEnabled = enableSystemControls;
        _smtc.IsPauseEnabled = enableSystemControls;
        _smtc.IsNextEnabled = enableSystemControls;
        _smtc.IsPreviousEnabled = enableSystemControls;
        _smtc.IsStopEnabled = enableSystemControls;
        if (enableSystemControls)
        {
            _smtc.ButtonPressed += SmtcOnButtonPressed;
            _smtc.PlaybackPositionChangeRequested += SmtcOnPlaybackPositionChangeRequested;
        }
        _pollTimer = new Timer(PollPlayback, null, Timeout.Infinite, Timeout.Infinite);
    }

    public AudioState State => _state;
    public AudioFormatInfo? Format => _input is null ? null : new AudioFormatInfo(
        _input.EncodingProperties.SampleRate,
        (int?)_input.EncodingProperties.BitsPerSample,
        (int?)_input.EncodingProperties.ChannelCount);
    public double TrackGainDb => _trackGainDb;

    public event EventHandler? StateChanged;
    public event EventHandler? PlaybackEnded;
    public event EventHandler<AudioErrorEventArgs>? Error;
    public event EventHandler<MediaRemoteCommandEventArgs>? RemoteCommand;

    public async Task OpenAsync(Uri source, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (!source.IsFile)
            throw new NotSupportedException("The AudioGraph backend expects a resolved local file URI.");

        await CloseGraphAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        try
        {
            var file = await StorageFile.GetFileFromPathAsync(source.LocalPath).AsTask(cancellationToken).ConfigureAwait(false);
            var settings = new AudioGraphSettings(AudioRenderCategory.Media);
            var graphResult = await AudioGraph.CreateAsync(settings).AsTask(cancellationToken).ConfigureAwait(false);
            if (graphResult.Status != AudioGraphCreationStatus.Success || graphResult.Graph is null)
                throw new InvalidOperationException($"AudioGraph creation failed: {graphResult.Status}");

            var graph = graphResult.Graph;
            var outputResult = await graph.CreateDeviceOutputNodeAsync().AsTask(cancellationToken).ConfigureAwait(false);
            if (outputResult.Status != AudioDeviceNodeCreationStatus.Success || outputResult.DeviceOutputNode is null)
            {
                graph.Close();
                throw new InvalidOperationException($"Audio output creation failed: {outputResult.Status}");
            }

            var mediaSource = MediaSource.CreateFromStorageFile(file);
            var inputResult = await graph.CreateMediaSourceAudioInputNodeAsync(mediaSource).AsTask(cancellationToken).ConfigureAwait(false);
            if (inputResult.Status != MediaSourceAudioInputNodeCreationStatus.Success || inputResult.Node is null)
            {
                outputResult.DeviceOutputNode.Close();
                graph.Close();
                mediaSource.Dispose();
                throw new InvalidOperationException($"Audio input creation failed: {inputResult.Status}");
            }

            var input = inputResult.Node;
            input.AddOutgoingConnection(outputResult.DeviceOutputNode);
            input.MediaSourceCompleted += InputOnMediaSourceCompleted;
            input.Stop();

            lock (_gate)
            {
                _graph = graph;
                _output = outputResult.DeviceOutputNode;
                _input = input;
                _source = mediaSource;
                ConfigureEqualizerLocked();
                _state = new AudioState(false, false, 0, input.Duration.TotalSeconds, _state.Volume);
            }

            graph.Start();
            graph.Stop();
            _pollTimer.Change(0, 150);
            UpdateSmtcState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            RaiseError(ex);
            throw;
        }
    }

    public void ApplyEffects(AudioEffectsSettings settings)
    {
        lock (_gate)
        {
            _effects = settings.Normalize();
            ConfigureEqualizerLocked();
        }
        StateChanged?.Invoke(this, EventArgs.Empty);
    }


    public void SetTrackGain(double gainDb)
    {
        try
        {
            lock (_gate)
            {
                _trackGainDb = Math.Clamp(double.IsFinite(gainDb) ? gainDb : 0, -96, 24);
                ApplyOutputGainLocked();
            }
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Play()
    {
        try
        {
            lock (_gate)
            {
                if (_input is null || _graph is null) return;
                _graph.Start();
                _input.Start();
                SetStateLocked(isPlaying: true);
            }
            UpdateSmtcState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Pause()
    {
        try
        {
            lock (_gate)
            {
                if (_input is null || _graph is null) return;
                _input.Stop();
                _graph.Stop();
                SetStateLocked(isPlaying: false);
            }
            UpdateSmtcState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Stop()
    {
        try
        {
            lock (_gate)
            {
                if (_input is null || _graph is null) return;
                _input.Stop();
                _input.Seek(TimeSpan.Zero);
                _graph.Stop();
                SetStateLocked(isPlaying: false, position: 0);
            }
            UpdateSmtcState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void Seek(double seconds)
    {
        try
        {
            lock (_gate)
            {
                if (_input is null) return;
                var duration = _input.Duration.TotalSeconds;
                var position = Math.Clamp(seconds, 0, Math.Max(0, duration));
                _input.Seek(TimeSpan.FromSeconds(position));
                SetStateLocked(position: position);
            }
            UpdateSmtcState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public void SetVolume(double normalizedVolume)
    {
        try
        {
            lock (_gate)
            {
                _state = _state with { Volume = Math.Clamp(normalizedVolume, 0, 1) };
                ApplyOutputGainLocked();
            }
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    public async Task UpdateNowPlayingArtworkAsync(byte[]? artwork, CancellationToken cancellationToken = default)
    {
        if (!_systemControlsEnabled) return;
        try
        {
            if (artwork is null || artwork.Length == 0)
            {
                _smtc.DisplayUpdater.Thumbnail = null;
                _smtc.DisplayUpdater.Update();
                return;
            }

            Directory.CreateDirectory(_smtcArtworkFolder);
            var hash = Convert.ToHexString(SHA256.HashData(artwork)).ToLowerInvariant();
            var path = Path.Combine(_smtcArtworkFolder, hash + DetectImageExtension(artwork));
            if (!File.Exists(path))
            {
                await File.WriteAllBytesAsync(path, artwork, cancellationToken).ConfigureAwait(false);
            }

            var file = await StorageFile.GetFileFromPathAsync(path).AsTask(cancellationToken).ConfigureAwait(false);
            _smtc.DisplayUpdater.Thumbnail = RandomAccessStreamReference.CreateFromFile(file);
            _smtc.DisplayUpdater.Update();
            PruneSmtcArtworkCache(path);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception ex) { AppLog.Warn("Could not update SMTC artwork.", ex); }
    }


    private void PruneSmtcArtworkCache(string currentPath)
    {
        try
        {
            var files = new DirectoryInfo(_smtcArtworkFolder).GetFiles("*.*")
                .Where(f => !string.Equals(f.FullName, currentPath, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .Skip(31);
            foreach (var file in files) file.Delete();
        }
        catch { }
    }

    private static string DetectImageExtension(byte[] data)
    {
        if (data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return ".jpg";
        if (data.Length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return ".png";
        if (data.Length >= 6 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return ".gif";
        if (data.Length >= 12 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 && data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50) return ".webp";
        return ".jpg";
    }

    public void UpdateNowPlaying(string? title, string? artist, string? album)
    {
        if (!_systemControlsEnabled) return;
        _smtc.DisplayUpdater.Type = MediaPlaybackType.Music;
        _smtc.DisplayUpdater.AppMediaId = "MusicPlayerWin";
        _smtc.DisplayUpdater.MusicProperties.Title = title ?? string.Empty;
        _smtc.DisplayUpdater.MusicProperties.Artist = artist ?? string.Empty;
        _smtc.DisplayUpdater.MusicProperties.AlbumTitle = album ?? string.Empty;
        _smtc.DisplayUpdater.Update();
        UpdateSmtcState();
    }

    /// <summary>Updates SMTC timeline/status from an external coordinator.
    /// This is used by the dual-deck engine because deck A can be in standby
    /// while deck B is the actual active output.
    /// </summary>
    public void UpdateSystemTransportState(AudioState state)
    {
        if (!_systemControlsEnabled) return;
        UpdateSmtcState(state);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _pollTimer.Dispose();
        if (_systemControlsEnabled)
        {
            _smtc.ButtonPressed -= SmtcOnButtonPressed;
            _smtc.PlaybackPositionChangeRequested -= SmtcOnPlaybackPositionChangeRequested;
        }
        await CloseGraphAsync().ConfigureAwait(false);
        _transport.Dispose();
    }

    private async Task CloseGraphAsync()
    {
        AudioGraph? graph;
        AudioDeviceOutputNode? output;
        MediaSourceAudioInputNode? input;
        MediaSource? source;
        lock (_gate)
        {
            graph = _graph;
            output = _output;
            input = _input;
            source = _source;
            _graph = null;
            _output = null;
            _input = null;
            _source = null;
            _equalizer = null;
            _state = _state with { IsPlaying = false, Position = 0, Duration = 0 };
        }

        _pollTimer.Change(Timeout.Infinite, Timeout.Infinite);
        if (input is not null)
        {
            try { input.MediaSourceCompleted -= InputOnMediaSourceCompleted; } catch { }
            try { input.Stop(); } catch { }
            try { input.Close(); } catch { }
        }
        try { graph?.Stop(); } catch { }
        try { output?.Close(); } catch { }
        try { graph?.Close(); } catch { }
        try { source?.Dispose(); } catch { }
        await Task.CompletedTask;
    }

    private void ConfigureEqualizerLocked()
    {
        if (_output is null || _graph is null) return;

        if (_equalizer is null)
        {
            _equalizer = new EqualizerEffectDefinition(_graph);
            for (var i = 0; i < Math.Min(10, _equalizer.Bands.Count); i++)
            {
                _equalizer.Bands[i].FrequencyCenter = AudioEffectsSettings.FrequenciesHz[i];
                _equalizer.Bands[i].Bandwidth = 1.0;
                _equalizer.Bands[i].Gain = _effects.Gains[i];
            }
            _output.EffectDefinitions.Add(_equalizer);
        }
        else
        {
            for (var i = 0; i < Math.Min(10, _equalizer.Bands.Count); i++)
                _equalizer.Bands[i].Gain = _effects.Gains[i];
        }

        if (_effects.EqualizerEnabled)
            _output.EnableEffectsByDefinition(_equalizer);
        else
            _output.DisableEffectsByDefinition(_equalizer);

        ApplyOutputGainLocked();
    }

    private void ApplyOutputGainLocked()
    {
        if (_output is null) return;
        var db = _effects.EqualizerEnabled ? _effects.EqualizerHeadroomDb : 0;
        var linearHeadroom = Math.Pow(10, db / 20.0);
        var replayGain = Math.Pow(10, Math.Clamp(_trackGainDb, -96, 24) / 20.0);
        _output.OutgoingGain = _state.Volume * linearHeadroom * replayGain;
    }

    private void PollPlayback(object? _)
    {
        try
        {
            lock (_gate)
            {
                if (_input is null) return;
                var position = _input.Position.TotalSeconds;
                var duration = _input.Duration.TotalSeconds;
                _state = _state with { Position = position, Duration = duration };
            }
            UpdateSmtcState();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { RaiseError(ex); }
    }

    private void InputOnMediaSourceCompleted(MediaSourceAudioInputNode sender, object args)
    {
        lock (_gate)
        {
            if (_input != sender) return;
            SetStateLocked(isPlaying: false, position: sender.Duration.TotalSeconds, duration: sender.Duration.TotalSeconds);
            _graph?.Stop();
        }
        UpdateSmtcState();
        StateChanged?.Invoke(this, EventArgs.Empty);
        PlaybackEnded?.Invoke(this, EventArgs.Empty);
    }

    private void SetStateLocked(bool? isPlaying = null, double? position = null, double? duration = null)
    {
        _state = _state with
        {
            IsPlaying = isPlaying ?? _state.IsPlaying,
            Position = position ?? _state.Position,
            Duration = duration ?? _state.Duration
        };
    }

    private void UpdateSmtcState() => UpdateSmtcState(_state);

    private void UpdateSmtcState(AudioState state)
    {
        if (!_systemControlsEnabled) return;
        var duration = Math.Max(0, state.Duration);
        var position = Math.Clamp(state.Position, 0, duration);
        _smtc.PlaybackStatus = state.IsPlaying
            ? MediaPlaybackStatus.Playing
            : position > 0 && position < duration
                ? MediaPlaybackStatus.Paused
                : MediaPlaybackStatus.Stopped;
        _smtc.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
        {
            StartTime = TimeSpan.Zero,
            EndTime = TimeSpan.FromSeconds(duration),
            Position = TimeSpan.FromSeconds(position),
            MinSeekTime = TimeSpan.Zero,
            MaxSeekTime = TimeSpan.FromSeconds(duration)
        });
    }

    private void SmtcOnPlaybackPositionChangeRequested(SystemMediaTransportControls sender, PlaybackPositionChangeRequestedEventArgs args)
    {
        try { Seek(args.RequestedPlaybackPosition.TotalSeconds); }
        catch (Exception ex) { RaiseError(ex); }
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
        if (command.HasValue) RemoteCommand?.Invoke(this, new MediaRemoteCommandEventArgs(command.Value));
    }

    private void RaiseError(Exception ex)
    {
        Error?.Invoke(this, new AudioErrorEventArgs(ex));
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(WindowsAudioGraphEngine));
    }
}
