namespace MusicPlayerWin.Core.Audio;

/// <summary>Snapshot of the audio engine that can be consumed by any UI.</summary>
public sealed record AudioState(
    bool IsPlaying = false,
    bool IsBuffering = false,
    double Position = 0,
    double Duration = 0,
    double Volume = 1);

/// <summary>Format information reported by the actual decoder when available.</summary>
public sealed record AudioFormatInfo(
    double? SampleRate = null,
    int? BitDepth = null,
    int? ChannelCount = null)
{
    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (BitDepth is int depth) parts.Add($"{depth} bit");
            if (SampleRate is double rate)
            {
                var khz = rate / 1000;
                parts.Add(Math.Abs(khz - Math.Round(khz)) < 0.0001
                    ? $"{khz:0} kHz"
                    : $"{khz:0.0} kHz");
            }

            switch (ChannelCount)
            {
                case 1: parts.Add("Mono"); break;
                case 2: parts.Add("Stereo"); break;
                case int count when count > 0: parts.Add($"{count} ch"); break;
            }

            return string.Join(" · ", parts);
        }
    }
}
