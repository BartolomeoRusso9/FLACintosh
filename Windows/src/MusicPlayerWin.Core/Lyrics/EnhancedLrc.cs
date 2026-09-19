using System.Collections.Immutable;
using System.Globalization;

namespace MusicPlayerWin.Core.Lyrics;

/// <summary>
/// Reads enhanced LRC — the format with a timestamp per *syllable*.
///
/// <code>
/// [ti:RATATA]
/// [ar:Capo Plaza]
///
/// [00:08.75]&lt;00:08.75&gt;Sento &lt;00:09.05&gt;un&lt;00:09.22&gt;ra-&lt;00:09.41&gt;ta- &lt;00:09.90&gt;ta
/// </code>
///
/// The <c>[mm:ss.xx]</c> opens the line; each <c>&lt;mm:ss.xx&gt;</c> opens a
/// syllable. Plain LRC — a line tag and nothing else — parses too, as a line
/// holding one syllable, so a caller never has to ask which dialect a file is
/// in.
///
/// This is the format SpotiFLAC writes with <c>--save-lrc</c>, which is in
/// turn what Apple's own timed lyrics look like once flattened; it is also
/// what Apple Music refuses to render for a local file, which is the whole
/// reason this parser exists.
///
/// Ported from <c>EnhancedLRC.swift</c>. Logic is a line-by-line translation,
/// checked against the original's fixture ("RATATA" by Capo Plaza) and every
/// assertion from <c>LyricsCheck/main.swift</c> — see
/// <c>EnhancedLrcTests.cs</c>. One intentional behavioural quirk is carried
/// over rather than "fixed": a stray, non-timestamp <c>&lt;</c> that appears
/// after syllables have already been parsed gets folded into the *first*
/// syllable's text, not the last one (see the "stray angle bracket" test).
/// That is what the original does, and matching it exactly is the point of a
/// port meant to be the same app.
/// </summary>
public static class EnhancedLrc
{
    /// <summary>A line's end when nothing follows it — the last line of a file has no successor to borrow a start time from.</summary>
    public const double TrailingLineDuration = 4;

    public static TimedLyrics Parse(string source)
    {
        var idTags = new Dictionary<string, string>();
        var pending = new List<(double Start, List<(double Time, string Text)> Syllables)>();

        foreach (var rawLine in source.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;

            var tag = IdTag(line);
            if (tag is not null)
            {
                idTags[tag.Value.Key] = tag.Value.Value;
                continue;
            }

            var (starts, body) = LineTimestamps(line);
            if (starts.Count == 0) continue;

            // Standard LRC lets one body carry several timestamps, for a
            // chorus repeated verbatim. Each becomes its own line.
            var syllables = Syllables(body);
            foreach (var start in starts)
            {
                pending.Add((start, syllables.Count == 0
                    ? new List<(double, string)> { (start, body) }
                    : syllables));
            }
        }

        pending.Sort((a, b) => a.Start.CompareTo(b.Start));

        var offset = idTags.TryGetValue("offset", out var offsetRaw)
                     && double.TryParse(offsetRaw, NumberStyles.Float, CultureInfo.InvariantCulture, out var offsetMs)
            ? offsetMs / 1000
            : 0;

        var lines = new List<LyricLine>(pending.Count);

        for (var index = 0; index < pending.Count; index++)
        {
            var entry = pending[index];
            var start = entry.Start + offset;
            var end = index + 1 < pending.Count
                ? pending[index + 1].Start + offset
                : start + TrailingLineDuration;

            var syllables = ImmutableArray.CreateBuilder<Syllable>(entry.Syllables.Count);
            for (var position = 0; position < entry.Syllables.Count; position++)
            {
                var (time, text) = entry.Syllables[position];
                var syllableStart = time + offset;
                var syllableEnd = position + 1 < entry.Syllables.Count
                    ? entry.Syllables[position + 1].Time + offset
                    : end;

                syllables.Add(new Syllable(syllableStart, Math.Max(syllableEnd, syllableStart), text));
            }

            // A line tag with no text at all marks an instrumental gap. It is
            // kept, not dropped: it is what stops the previous line from
            // staying lit through a thirty-second break.
            lines.Add(new LyricLine(lines.Count, start, end, syllables.ToImmutable()));
        }

        return new TimedLyrics(
            Title: idTags.GetValueOrDefault("ti"),
            Artist: idTags.GetValueOrDefault("ar"),
            Album: idTags.GetValueOrDefault("al"),
            Lines: lines.ToImmutableArray());
    }

    // Pieces

    /// <summary>
    /// <c>[ti:RATATA]</c> → ("ti", "RATATA"). Null for anything time-shaped.
    ///
    /// Telling an id tag from a line tag is the one decision in this format
    /// people get wrong, and it is worth being able to check it directly.
    /// </summary>
    public static (string Key, string Value)? IdTag(string line)
    {
        if (!line.StartsWith('[') || !line.EndsWith(']')) return null;
        var colon = line.IndexOf(':');
        if (colon < 0) return null;

        var key = line[1..colon].Trim().ToLowerInvariant();
        // A timestamp's "key" is its minutes. Digits mean this is a line, not
        // an id tag — and "offset" is the one id tag whose value is numeric,
        // which is why the *key* decides and not the value.
        if (key.Length == 0 || !key.All(char.IsLetter)) return null;

        var value = line[(colon + 1)..^1].Trim();
        return (key, value);
    }

    /// <summary>Peels the leading <c>[mm:ss.xx]</c> tags off a line, returning them and the body that follows.</summary>
    internal static (List<double> Starts, string Body) LineTimestamps(string line)
    {
        var starts = new List<double>();
        var rest = line;

        while (rest.StartsWith('['))
        {
            var close = rest.IndexOf(']');
            if (close < 0) break;

            var inside = rest[1..close];
            var seconds = Timestamp(inside);
            if (seconds is null) break;

            starts.Add(seconds.Value);
            rest = rest[(close + 1)..];
        }

        return (starts, rest);
    }

    /// <summary>
    /// Splits a line body into its <c>&lt;mm:ss.xx&gt;text</c> fragments.
    ///
    /// Any text before the first <c>&lt;</c> belongs to nothing — a
    /// well-formed enhanced line opens with a tag — so it is attached to the
    /// first syllable rather than silently dropped.
    /// </summary>
    internal static List<(double Time, string Text)> Syllables(string body)
    {
        if (!body.Contains('<')) return new List<(double, string)>();

        var result = new List<(double Time, string Text)>();
        var prefix = "";
        var rest = body;

        while (true)
        {
            var open = rest.IndexOf('<');
            if (open < 0) break;

            var leading = rest[..open];
            var close = rest.IndexOf('>', open);
            var seconds = close >= 0 ? Timestamp(rest[(open + 1)..close]) : null;

            if (close < 0 || seconds is null)
            {
                // A stray "<" that is not a timestamp: keep it as text.
                prefix += rest[..(open + 1)];
                rest = rest[(open + 1)..];
                continue;
            }

            if (result.Count == 0)
                prefix += leading;
            else
                result[^1] = (result[^1].Time, result[^1].Text + leading);

            result.Add((seconds.Value, ""));
            rest = rest[(close + 1)..];
        }

        if (rest.Length > 0)
        {
            if (result.Count == 0)
                prefix += rest;
            else
                result[^1] = (result[^1].Time, result[^1].Text + rest);
        }

        if (prefix.Length > 0 && result.Count > 0)
            result[0] = (result[0].Time, prefix + result[0].Text);

        return result.Where(s => s.Text.Length > 0).ToList();
    }

    /// <summary>
    /// <c>01:23.45</c> → 83.45. Accepts <c>mm:ss</c>, <c>mm:ss.xx</c>,
    /// <c>mm:ss.xxx</c>, and the <c>mm:ss:xx</c> some writers emit.
    /// </summary>
    public static double? Timestamp(string raw)
    {
        var text = raw.Trim();
        var colon = text.IndexOf(':');
        if (colon < 0) return null;

        var minutesPart = text[..colon];
        if (minutesPart.Length == 0 || !minutesPart.All(char.IsDigit)) return null;
        var minutes = double.Parse(minutesPart, CultureInfo.InvariantCulture);

        var secondsPart = text[(colon + 1)..];
        double fraction = 0;

        var separator = secondsPart.IndexOfAny(['.', ':']);
        if (separator >= 0)
        {
            var digits = secondsPart[(separator + 1)..];
            if (digits.Length == 0 || !digits.All(char.IsDigit)) return null;
            fraction = double.Parse(digits, CultureInfo.InvariantCulture) / Math.Pow(10, digits.Length);
            secondsPart = secondsPart[..separator];
        }

        if (secondsPart.Length == 0 || !secondsPart.All(char.IsDigit)) return null;
        var seconds = double.Parse(secondsPart, CultureInfo.InvariantCulture);

        return minutes * 60 + seconds + fraction;
    }
}
