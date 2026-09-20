using System.Globalization;
using System.Text;

namespace MusicPlayerWin.Core.Library;

/// <summary>
/// Whether the library already has a record or a song found elsewhere — a
/// catalogue search, say, where nothing shares an identifier with the files.
///
/// Same title and artist once both are reduced to their letters and digits,
/// with the edition notes a catalogue adds — "(Remastered 2011)",
/// "[Deluxe]", "- Single" — dropped. Deliberately forgiving: a wrong "In
/// Library" costs a click to download anyway, a missed one a duplicate.
/// </summary>
public static class LibraryMatch
{
    public static bool HasAlbum(string title, string artist, LibraryStore library)
    {
        var titleKey = Key(title);
        var artistKey = Key(artist);
        if (titleKey.Length == 0) return false;
        return library.Albums.Any(a => Key(a.Title) == titleKey && SameArtist(Key(a.Artist), artistKey));
    }

    public static bool HasSong(string title, string artist, LibraryStore library)
    {
        var titleKey = Key(title);
        var artistKey = Key(artist);
        if (titleKey.Length == 0) return false;
        return library.Tracks.Any(t => Key(t.Title) == titleKey && SameArtist(Key(t.Artist), artistKey));
    }

    /// <summary>
    /// Catalogues list every credited artist, libraries often only the
    /// first: "Artist A, Artist B" matches a library that says "Artist A".
    /// </summary>
    private static bool SameArtist(string library, string catalogue)
    {
        if (library.Length == 0 || catalogue.Length == 0) return true;
        return library == catalogue || catalogue.StartsWith(library, StringComparison.Ordinal) || library.StartsWith(catalogue, StringComparison.Ordinal);
    }

    public static string Key(string text)
    {
        var cleaned = text;
        foreach (var (open, close) in new[] { ('(', ')'), ('[', ']') })
        {
            int start;
            while ((start = cleaned.IndexOf(open)) >= 0)
            {
                var end = cleaned.IndexOf(close, start + 1);
                if (end < 0) break;
                cleaned = cleaned.Remove(start, end - start + 1);
            }
        }

        var dash = cleaned.IndexOf(" - ", StringComparison.Ordinal);
        if (dash >= 0) cleaned = cleaned[..dash];

        var folded = cleaned.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(folded.Length);
        foreach (var ch in folded)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark) continue;
            if (char.IsLetterOrDigit(ch)) builder.Append(char.ToLowerInvariant(ch));
        }
        return builder.ToString();
    }
}
