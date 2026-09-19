namespace MusicPlayerWin.Core.Audio;

/// <summary>
/// Persisted playback-processing settings. The ten bands intentionally mirror
/// the FLACintosh graphic EQ so presets can be ported one-to-one.
/// </summary>
public sealed record AudioEffectsSettings
{
    public static readonly double[] FrequenciesHz = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    public static readonly string[] BandLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"];

    public static readonly IReadOnlyDictionary<string, double[]> Presets =
        new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase)
        {
            ["Flat"] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            ["Bass Booster"] = [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0],
            ["Bass Reducer"] = [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0],
            ["Treble Booster"] = [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6],
            ["Treble Reducer"] = [0, 0, 0, 0, 0, -1, -2.5, -4, -5, -6],
            ["Vocal Booster"] = [-2, -3, -3, 1, 4, 4, 3.5, 1.5, 0, -2],
            ["Loudness"] = [6, 4, 0, 0, -2, 0, -1, -5, 5, 1],
            ["Acoustic"] = [5, 5, 4, 1, 2, 2, 3.5, 4, 3.5, 2],
            ["Classical"] = [5, 4, 3.5, 3, -1.5, -1.5, 0, 2, 3.5, 4],
            ["Dance"] = [3.5, 6.5, 5, 0, 2, 3.5, 5, 4, 3.5, 0],
            ["Electronic"] = [4, 3.5, 1, 0, -2, 2, 1, 1, 4, 5],
            ["Hip-Hop"] = [5, 4, 1, 3, -1, -1, 1, -0.5, 2, 3],
            ["Jazz"] = [4, 3, 1, 2, -1.5, -1.5, 0, 1.5, 3, 3.5],
            ["Pop"] = [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5],
            ["R&B"] = [2.5, 7, 5.5, 1.5, -2, -1.5, 2, 2.5, 3, 3.5],
            ["Rock"] = [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5],
            ["Late Night"] = [4, 3, 2, 0, -1, -1, 0, 1, 2, 3],
            ["Small Speakers"] = [5.5, 4, 3.5, 2.5, 1.5, 0, -1.5, -2.5, -3.5, -4],
            ["Spoken Word"] = [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4, 2.5, 0]
        };

    public static AudioEffectsSettings Default => new();

    public bool EqualizerEnabled { get; init; }
    public double[] Gains { get; init; } = new double[10];
    public string PresetName { get; init; } = "Flat";
    public bool Gapless { get; init; } = true;
    public bool Crossfade { get; init; }
    public double CrossfadeSeconds { get; init; } = 4;
    public ReplayGainMode ReplayGain { get; init; } = ReplayGainMode.Off;
    public double ReplayGainPreamp { get; init; }

    public double EqualizerHeadroomDb => EqualizerEnabled ? -Math.Max(0, Gains.Length == 0 ? 0 : Gains.Max()) : 0;

    public AudioEffectsSettings Normalize()
    {
        var source = Gains ?? Array.Empty<double>();
        var gains = new double[10];
        for (var i = 0; i < gains.Length; i++)
            gains[i] = i < source.Length ? Math.Clamp(source[i], -12, 12) : 0;

        var preset = PresetName;
        if (!Presets.TryGetValue(preset, out var presetGains) || !presetGains.SequenceEqual(gains))
            preset = Presets.FirstOrDefault(x => x.Value.SequenceEqual(gains)).Key ?? "Custom";

        return this with
        {
            Gains = gains,
            PresetName = preset,
            CrossfadeSeconds = Math.Clamp(CrossfadeSeconds, 0, 12),
            ReplayGainPreamp = Math.Clamp(ReplayGainPreamp, -12, 12)
        };
    }

    public enum ReplayGainMode
    {
        Off,
        Track,
        Album
    }
}
