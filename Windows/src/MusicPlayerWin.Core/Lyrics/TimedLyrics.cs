using System.Collections.Immutable;

namespace MusicPlayerWin.Core.Lyrics;

/// <summary>
/// One timed fragment of a line.
///
/// A syllable, not a word: Apple times "expressions" as ex|pres|sions, and
/// that is what makes the highlight travel *through* a long word instead of
/// jumping over it.
///
/// <c>Text</c> keeps whatever trailing space it had, so concatenating every
/// syllable of a line reproduces the line exactly. That is deliberate — the
/// alternative is an "is word continuation" flag that every renderer then has
/// to remember to honour, and forgetting it is how "make expressions" comes
/// out as "makeexpressions".
/// </summary>
public readonly record struct Syllable(double Start, double End, string Text)
{
    /// <summary>How far through this syllable <paramref name="time"/> is, clamped to 0...1.</summary>
    public double Progress(double time)
    {
        if (End <= Start) return time >= Start ? 1 : 0;
        var value = (time - Start) / (End - Start);
        return Math.Min(Math.Max(value, 0), 1);
    }
}

/// <summary>One line of lyrics, with per-syllable timing where the source had it.</summary>
public sealed record LyricLine(int Id, double Start, double End, ImmutableArray<Syllable> Syllables)
{
    /// <summary>The whole line as plain text.</summary>
    public string Text => string.Concat(Syllables.Select(s => s.Text));

    /// <summary>
    /// Whether this line carries real per-syllable timing.
    ///
    /// A line parsed from plain LRC becomes a single syllable spanning the
    /// whole line, so a renderer can treat both kinds the same way and only
    /// consult this to decide whether a word-by-word sweep means anything.
    /// </summary>
    public bool HasWordTiming => Syllables.Length > 1;

    public bool Contains(double time) => time >= Start && time < End;
}

/// <summary>A parsed lyrics file: the id tags, and the lines in time order.</summary>
public sealed record TimedLyrics(
    string? Title = null,
    string? Artist = null,
    string? Album = null,
    ImmutableArray<LyricLine> Lines = default)
{
    private ImmutableArray<LyricLine> LinesOrEmpty =>
        Lines.IsDefault ? ImmutableArray<LyricLine>.Empty : Lines;

    public bool IsEmpty => LinesOrEmpty.Length == 0;

    /// <summary>
    /// True when at least one line has syllable timing — i.e. when a
    /// word-by-word display is worth showing at all.
    /// </summary>
    public bool HasWordTiming => LinesOrEmpty.Any(l => l.HasWordTiming);

    /// <summary>
    /// The index of the line playing at <paramref name="time"/>, or the last
    /// one before it.
    ///
    /// Binary search rather than a scan: this is called on every frame.
    /// Returns null before the first line starts.
    /// </summary>
    public int? LineIndex(double time)
    {
        var lines = LinesOrEmpty;
        if (lines.Length == 0 || time < lines[0].Start) return null;

        int low = 0, high = lines.Length - 1, found = 0;
        while (low <= high)
        {
            var mid = (low + high) / 2;
            if (lines[mid].Start <= time)
            {
                found = mid;
                low = mid + 1;
            }
            else
            {
                high = mid - 1;
            }
        }

        return found;
    }
}
