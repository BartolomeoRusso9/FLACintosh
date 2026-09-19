using TagLib;
using IOFile = System.IO.File;

namespace MusicPlayerWin.Core.Metadata;

/// <summary>
/// Reads and writes the common tag fields used by FLACintosh's Get Info view.
/// Local files only; server records remain read-only in the library.
/// </summary>
public sealed record AudioMetadataFields(
    string Title,
    string Artist,
    string AlbumArtist,
    string Album,
    string Genre,
    string Year,
    string TrackNumber,
    string DiscNumber);

public sealed class AudioMetadataEditor
{
    public AudioMetadataFields Read(Uri fileUri)
    {
        EnsureLocal(fileUri);
        using var file = TagLib.File.Create(fileUri.LocalPath);
        var tag = file.Tag;
        return new AudioMetadataFields(
            tag.Title ?? string.Empty,
            First(tag.Performers),
            First(tag.AlbumArtists),
            tag.Album ?? string.Empty,
            First(tag.Genres),
            tag.Year > 0 ? tag.Year.ToString() : string.Empty,
            tag.Track > 0 ? tag.Track.ToString() : string.Empty,
            tag.Disc > 0 ? tag.Disc.ToString() : string.Empty);
    }

    public void Write(Uri fileUri, AudioMetadataFields fields)
    {
        EnsureLocal(fileUri);
        using var file = TagLib.File.Create(fileUri.LocalPath);
        var tag = file.Tag;

        tag.Title = Clean(fields.Title);
        tag.Performers = SingleOrEmpty(fields.Artist);
        tag.AlbumArtists = SingleOrEmpty(fields.AlbumArtist);
        tag.Album = Clean(fields.Album);
        tag.Genres = SingleOrEmpty(fields.Genre);
        tag.Year = ParseUInt(fields.Year);
        tag.Track = ParseUInt(fields.TrackNumber);
        tag.Disc = ParseUInt(fields.DiscNumber);
        file.Save();
    }

    private static void EnsureLocal(Uri uri)
    {
        if (uri is null || !uri.IsFile)
            throw new ArgumentException("Metadata editing is available only for local files.", nameof(uri));
        if (!IOFile.Exists(uri.LocalPath))
            throw new FileNotFoundException("The audio file no longer exists.", uri.LocalPath);
    }

    private static string First(string[]? values) =>
        values?.FirstOrDefault(x => !string.IsNullOrWhiteSpace(x))?.Trim() ?? string.Empty;

    private static string[] SingleOrEmpty(string value) =>
        string.IsNullOrWhiteSpace(value) ? Array.Empty<string>() : [value.Trim()];

    private static string? Clean(string value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static uint ParseUInt(string value) =>
        uint.TryParse(value.Trim(), out var parsed) ? parsed : 0;
}
