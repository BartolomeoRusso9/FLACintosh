namespace MusicPlayerWin.Core.Audio;

/// <summary>Optional processing surface implemented by platform audio engines.</summary>
public interface IAudioEffectsEngine
{
    void ApplyEffects(AudioEffectsSettings settings);
}
