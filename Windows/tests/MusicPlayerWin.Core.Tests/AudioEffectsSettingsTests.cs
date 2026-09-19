using MusicPlayerWin.Core.Audio;

namespace MusicPlayerWin.Core.Tests;

public sealed class AudioEffectsSettingsTests
{
    [Fact]
    public void NormalizePadsAndClampsAllBands()
    {
        var settings = new AudioEffectsSettings
        {
            Gains = [20, -20, 1]
        }.Normalize();

        Assert.Equal(10, settings.Gains.Length);
        Assert.Equal(12, settings.Gains[0]);
        Assert.Equal(-12, settings.Gains[1]);
        Assert.Equal(1, settings.Gains[2]);
        Assert.All(settings.Gains.Skip(3), gain => Assert.Equal(0, gain));
        Assert.Equal("Custom", settings.PresetName);
    }

    [Fact]
    public void PresetProducesExactTenBandCurve()
    {
        var curve = AudioEffectsSettings.Presets["Rock"];
        Assert.Equal(10, curve.Length);
        Assert.Equal(5, curve[0]);
        Assert.Equal(4.5, curve[9]);
    }

    [Fact]
    public void HeadroomFollowsPositiveBoost()
    {
        var settings = new AudioEffectsSettings
        {
            EqualizerEnabled = true,
            Gains = [0, 0, 6, 3, 0, 0, 0, 0, 0, 0]
        };

        Assert.Equal(-6, settings.EqualizerHeadroomDb);
    }
}
