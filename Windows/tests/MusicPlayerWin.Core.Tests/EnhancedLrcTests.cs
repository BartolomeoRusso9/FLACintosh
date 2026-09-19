using MusicPlayerWin.Core.Lyrics;
using Xunit;

namespace MusicPlayerWin.Core.Tests;

/// <summary>
/// Every check here is a direct port of the assertions in the original
/// project's <c>Sources/LyricsCheck/main.swift</c> — including the fixture
/// text (Capo Plaza's "RATATA", the file the whole feature exists to
/// render). If these pass, the C# parser agrees with the Swift one on every
/// documented behaviour, not just the happy path.
/// </summary>
public class EnhancedLrcTests
{
    private const string Ratata = """
        [ti:RATATA]
        [ar:Capo Plaza]
        [by:SpotiFLAC]

        [00:08.75]<00:08.75>Sento <00:09.05>un<00:09.22>ra-<00:09.41>ta- <00:09.90>ta
        [00:10.94]<00:10.94>Sento <00:11.39>un<00:11.56>ra-<00:11.77>ta-<00:12.00>ta- <00:12.91>ta
        """;

    [Fact]
    public void EnhancedLrc_TheFormatSpotiFlacWrites()
    {
        var lyrics = EnhancedLrc.Parse(Ratata);

        Assert.Equal("RATATA", lyrics.Title); // id tags become metadata
        Assert.Equal("Capo Plaza", lyrics.Artist); // artist id tag
        Assert.Equal(2, lyrics.Lines.Length); // id tags are not lines

        var line = lyrics.Lines[0];
        Assert.Equal(8.75, line.Start); // line start
        Assert.Equal(5, line.Syllables.Length); // one entry per syllable
        // The spaces live inside the syllables, so joining them is lossless —
        // "un" and "ra-" belong to one word and must not gain a space.
        Assert.Equal("Sento unra-ta- ta", line.Text); // the line reads back whole
        Assert.True(line.HasWordTiming); // a syllable-timed line says so

        Assert.Equal(9.05, line.Syllables[0].End); // a syllable ends where the next starts
        Assert.Equal(10.94, line.Syllables[^1].End); // the last syllable runs to the line's end
        Assert.Equal(
            lyrics.Lines[1].Start + EnhancedLrc.TrailingLineDuration,
            lyrics.Lines[1].End); // the last line gets an end with nothing after it
    }

    [Fact]
    public void PlainLrc_TheOtherDialect()
    {
        var lyrics = EnhancedLrc.Parse("[00:12.00]Just a line\n[00:15.00]And another");
        Assert.Equal(2, lyrics.Lines.Length); // two lines
        Assert.Equal("Just a line", lyrics.Lines[0].Text); // text survives
        Assert.False(lyrics.Lines[0].HasWordTiming); // no syllable timing is reported as such
        Assert.False(lyrics.HasWordTiming); // and the file agrees

        var chorus = EnhancedLrc.Parse("[00:10.00][01:20.00]Chorus");
        Assert.Equal(2, chorus.Lines.Length); // one body under two timestamps becomes two lines
        Assert.Equal([10, 80], chorus.Lines.Select(l => l.Start)); // both timestamps kept

        var shifted = EnhancedLrc.Parse("[offset:+500]\n[00:10.00]Late");
        Assert.Equal(10.5, shifted.Lines[0].Start); // offset shifts every timestamp
    }

    [Fact]
    public void Lookup()
    {
        var lyrics = EnhancedLrc.Parse(Ratata);
        Assert.Null(lyrics.LineIndex(0)); // nothing is playing before the first line
        Assert.Equal(0, lyrics.LineIndex(9.0)); // inside the first line
        Assert.Equal(1, lyrics.LineIndex(10.94)); // exactly on a line's start
        Assert.Equal(1, lyrics.LineIndex(600)); // past the end, the last line stays

        var syllable = new Syllable(10, 12, "ta");
        Assert.Equal(0, syllable.Progress(9)); // before
        Assert.Equal(0.5, syllable.Progress(11)); // halfway
        Assert.Equal(1, syllable.Progress(99)); // after

        // A zero-length syllable is on or off, never a division by zero.
        var instant = new Syllable(10, 10, "ta");
        Assert.Equal(0, instant.Progress(9.9)); // zero-length syllable, before
        Assert.Equal(1, instant.Progress(10)); // zero-length syllable, on
    }

    [Fact]
    public void WhatRealFilesDoWrong()
    {
        Assert.Equal(83.45, EnhancedLrc.Timestamp("01:23.45")); // mm:ss.xx
        Assert.Equal(83, EnhancedLrc.Timestamp("01:23")); // mm:ss
        Assert.Equal(83.456, EnhancedLrc.Timestamp("01:23.456")); // mm:ss.xxx
        Assert.Equal(83.45, EnhancedLrc.Timestamp("01:23:45")); // colon for the fraction
        Assert.Null(EnhancedLrc.Timestamp("nonsense")); // not a timestamp
        Assert.Null(EnhancedLrc.Timestamp("[00:01.00]")); // brackets are not part of it

        Assert.Equal("ti", EnhancedLrc.IdTag("[ti:RATATA]")?.Key); // an id tag
        Assert.Null(EnhancedLrc.IdTag("[00:08.75]Sento")); // a timestamp is not an id tag
        // The one id tag with a numeric value — the key has to decide.
        Assert.Equal("+500", EnhancedLrc.IdTag("[offset:+500]")?.Value); // offset is an id tag

        var messy = EnhancedLrc.Parse("\n\nnot a lyric line\n[00:01.00]Real\n   \n");
        Assert.Single(messy.Lines); // junk between lines is skipped

        Assert.True(EnhancedLrc.Parse("").IsEmpty); // an empty file is empty, not a crash
        Assert.True(EnhancedLrc.Parse("[ti:Only metadata]").IsEmpty); // metadata alone is no lyrics

        var unordered = EnhancedLrc.Parse("[00:30.00]Third\n[00:10.00]First\n[00:20.00]Second");
        Assert.Equal(["First", "Second", "Third"], unordered.Lines.Select(l => l.Text)); // lines are sorted

        var stray = EnhancedLrc.Parse("[00:01.00]<00:01.00>2 < 3 <00:02.00>always");
        Assert.Equal("2 < 3 always", stray.Lines[0].Text); // a stray angle bracket stays text
    }
}
