namespace MusicPlayerWin.Core.Audio;

/// <summary>Optional per-track gain surface, used by ReplayGain.</summary>
public interface ITrackGainAudioEngine
{
    double TrackGainDb { get; }
    void SetTrackGain(double gainDb);
}
