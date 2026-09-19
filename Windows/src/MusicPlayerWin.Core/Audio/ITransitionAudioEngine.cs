namespace MusicPlayerWin.Core.Audio;

/// <summary>Optional dual-deck transition surface for gapless/crossfade playback.</summary>
public interface ITransitionAudioEngine
{
    bool IsTransitioning { get; }
    bool HasPreparedNext { get; }

    event EventHandler? TransitionCompleted;

    void ConfigureTransition(bool gapless, bool crossfade, double crossfadeSeconds);
    Task PrepareNextAsync(Uri source, double trackGainDb, CancellationToken cancellationToken = default);
    void CancelPreparedNext();
}
