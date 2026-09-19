namespace MusicPlayerWin.Core.Audio;

/// <summary>
/// Platform-independent audio contract. The WinUI app supplies the concrete
/// implementation (for example a Windows Media Player/MediaPlayer backend).
/// </summary>
public interface IAudioEngine : IAsyncDisposable
{
    AudioState State { get; }
    AudioFormatInfo? Format { get; }

    event EventHandler? StateChanged;
    event EventHandler? PlaybackEnded;
    event EventHandler<AudioErrorEventArgs>? Error;

    Task OpenAsync(Uri source, CancellationToken cancellationToken = default);
    void Play();
    void Pause();
    void Stop();
    void Seek(double seconds);
    void SetVolume(double normalizedVolume);
}
