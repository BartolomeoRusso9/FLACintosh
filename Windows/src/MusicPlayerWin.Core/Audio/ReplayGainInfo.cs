using System.Globalization;
using TagLib;

namespace MusicPlayerWin.Core.Audio;

/// <summary>
/// ReplayGain metadata as stored by common taggers. The values are dB gains;
/// peaks are linear sample peaks.
/// </summary>
public sealed record ReplayGainInfo(
    double? TrackGain,
    double? TrackPeak,
    double? AlbumGain,
    double? AlbumPeak)
{
    public bool HasAnyGain => TrackGain.HasValue || AlbumGain.HasValue;

    public double GainFor(AudioEffectsSettings.ReplayGainMode mode, double preamp)
    {
        var (gain, peak) = mode switch
        {
            AudioEffectsSettings.ReplayGainMode.Track => (TrackGain ?? AlbumGain, TrackPeak ?? AlbumPeak),
            AudioEffectsSettings.ReplayGainMode.Album => (AlbumGain ?? TrackGain, AlbumPeak ?? TrackPeak),
            _ => (null, null)
        };

        if (!gain.HasValue) return 0;

        var total = gain.Value + preamp;
        if (peak is > 0 and < double.PositiveInfinity)
            total = Math.Min(total, -20 * Math.Log10(peak.Value));

        return double.IsFinite(total) ? total : 0;
    }
}

/// <summary>Reads ReplayGain from Vorbis/Xiph and APE custom fields.</summary>
public static class ReplayGainReader
{
    public static ReplayGainInfo? Read(Uri source)
    {
        if (source is null || !source.IsFile || !File.Exists(source.LocalPath)) return null;

        try
        {
            using var file = TagLib.File.Create(source.LocalPath);
            var xiph = file.GetTag(TagTypes.Xiph) as TagLib.Ogg.XiphComment;
            var ape = file.GetTag(TagTypes.Ape) as TagLib.Ape.Tag;

            var info = new ReplayGainInfo(
                Parse(ReadXiph(xiph, "REPLAYGAIN_TRACK_GAIN") ?? ReadApe(ape, "REPLAYGAIN_TRACK_GAIN")),
                Parse(ReadXiph(xiph, "REPLAYGAIN_TRACK_PEAK") ?? ReadApe(ape, "REPLAYGAIN_TRACK_PEAK")),
                Parse(ReadXiph(xiph, "REPLAYGAIN_ALBUM_GAIN") ?? ReadApe(ape, "REPLAYGAIN_ALBUM_GAIN")),
                Parse(ReadXiph(xiph, "REPLAYGAIN_ALBUM_PEAK") ?? ReadApe(ape, "REPLAYGAIN_ALBUM_PEAK")));

            return info.HasAnyGain ? info : null;
        }
        catch
        {
            return null;
        }
    }

    private static string? ReadXiph(TagLib.Ogg.XiphComment? tag, string name)
    {
        if (tag is null) return null;
        return tag.GetField(name)?.FirstOrDefault(x => !string.IsNullOrWhiteSpace(x));
    }

    private static string? ReadApe(TagLib.Ape.Tag? tag, string name)
    {
        if (tag is null) return null;
        try
        {
            var item = tag.GetItem(name);
            return item is null ? null : item.ToString();
        }
        catch
        {
            return null;
        }
    }

    private static double? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var value = text.Trim().Replace(" dB", "", StringComparison.OrdinalIgnoreCase);
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) && double.IsFinite(parsed)
            ? parsed
            : null;
    }
}
