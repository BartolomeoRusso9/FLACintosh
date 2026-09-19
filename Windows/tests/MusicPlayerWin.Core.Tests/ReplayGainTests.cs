using MusicPlayerWin.Core.Audio;

namespace MusicPlayerWin.Core.Tests;

public sealed class ReplayGainTests
{
    [Fact]
    public void TrackModeFallsBackToAlbumGainAndAppliesPreamp()
    {
        var info = new ReplayGainInfo(null, null, -7.5, 0.5);

        var gain = info.GainFor(AudioEffectsSettings.ReplayGainMode.Track, 1.5);

        Assert.Equal(-6.0, gain, 6);
    }

    [Fact]
    public void PeakGuardPreventsPositiveGainAboveFullScale()
    {
        var info = new ReplayGainInfo(3.0, 0.5, null, null);

        var gain = info.GainFor(AudioEffectsSettings.ReplayGainMode.Track, 0);

        Assert.Equal(-20 * Math.Log10(0.5), gain, 6);
    }

    [Fact]
    public void OffModeReturnsZero()
    {
        var info = new ReplayGainInfo(-8, 0.8, -6, 0.9);

        Assert.Equal(0, info.GainFor(AudioEffectsSettings.ReplayGainMode.Off, 10));
    }
}
