using System.Collections.Concurrent;
using TagLib;
using IOFile = System.IO.File;

namespace MusicPlayerWin.Core.Library;

/// <summary>Scanned local-library record.</summary>
public sealed record LibraryScanBatch(
    IReadOnlyList<LibraryTrack> Tracks,
    IReadOnlyDictionary<string, byte[]> Covers);

/// <summary>
/// Walks a music folder and reads metadata off the UI thread.
/// The behaviour mirrors FLACintosh's LibraryScanner: supported audio files
/// are discovered first and metadata is read in bounded parallel batches.
/// </summary>
public static class LibraryScanner
{
    public static readonly IReadOnlySet<string> AudioExtensions = new HashSet<string>(
        StringComparer.OrdinalIgnoreCase)
    {
        ".flac", ".m4a", ".mp3", ".aiff", ".aif", ".wav", ".alac", ".ogg", ".oga", ".opus",
        ".wv", ".ape", ".mpc", ".dsf", ".dff", ".aac", ".m4b", ".shn", ".tta"
    };

    public static async Task<IReadOnlyList<Uri>> AudioFilesAsync(
        string root,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(root)) throw new ArgumentException("A library folder is required.", nameof(root));
        if (!Directory.Exists(root)) return Array.Empty<Uri>();

        return await Task.Run(() =>
        {
            var results = new List<Uri>();
            var options = new EnumerationOptions
            {
                RecurseSubdirectories = true,
                IgnoreInaccessible = true,
                ReturnSpecialDirectories = false,
                AttributesToSkip = FileAttributes.Hidden | FileAttributes.System
            };

            foreach (var file in Directory.EnumerateFiles(root, "*", options))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (AudioExtensions.Contains(Path.GetExtension(file)))
                    results.Add(new Uri(Path.GetFullPath(file)));
            }

            results.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.LocalPath, b.LocalPath));
            return (IReadOnlyList<Uri>)results;
        }, cancellationToken).ConfigureAwait(false);
    }

    public static async IAsyncEnumerable<LibraryScanBatch> ReadAsync(
        IReadOnlyList<Uri> files,
        int batchSize = 24,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (batchSize <= 0) throw new ArgumentOutOfRangeException(nameof(batchSize));
        if (files.Count == 0) yield break;

        for (var start = 0; start < files.Count; start += batchSize)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var slice = files.Skip(start).Take(batchSize).ToArray();
            var scanned = new ConcurrentBag<Scanned>();

            await Parallel.ForEachAsync(
                slice,
                new ParallelOptions
                {
                    CancellationToken = cancellationToken,
                    MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount / 2)
                },
                (uri, ct) =>
                {
                    var item = Scan(uri);
                    if (item is not null) scanned.Add(item);
                    return ValueTask.CompletedTask;
                }).ConfigureAwait(false);

            var tracks = scanned
                .OrderBy(x => x.Track.Id.LocalPath, StringComparer.OrdinalIgnoreCase)
                .Select(x => x.Track)
                .ToList();

            var covers = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            foreach (var item in scanned.OrderBy(x => x.Track.Id.LocalPath, StringComparer.OrdinalIgnoreCase))
            {
                var albumId = AlbumId(item.Track.AlbumArtist, item.Track.Album);
                if (!covers.ContainsKey(albumId) && item.Cover is { Length: > 0 })
                    covers[albumId] = item.Cover;
            }

            if (tracks.Count > 0)
                yield return new LibraryScanBatch(tracks, covers);
        }
    }

    public static IReadOnlyList<LibraryAlbum> Group(
        IEnumerable<LibraryTrack> tracks,
        IReadOnlyDictionary<string, byte[]>? covers = null)
    {
        covers ??= new Dictionary<string, byte[]>();

        return tracks
            .GroupBy(t => $"{t.Source.Key}\u001E{AlbumId(t.AlbumArtist, t.Album)}", StringComparer.Ordinal)
            .Select(group =>
            {
                var ordered = group
                    .OrderBy(t => t.DiscNumber ?? 1)
                    .ThenBy(t => t.TrackNumber ?? 0)
                    .ThenBy(t => t.Title, StringComparer.OrdinalIgnoreCase)
                    .ToList();

                var separator = group.Key.IndexOf('\u001E');
                var albumId = separator >= 0 ? group.Key[(separator + 1)..] : group.Key;
                var modified = ordered
                    .Where(t => t.Id.IsFile)
                    .Select(t =>
                    {
                        try { return IOFile.GetLastWriteTimeUtc(t.Id.LocalPath); }
                        catch { return DateTime.MinValue; }
                    })
                    .DefaultIfEmpty(DateTime.MinValue)
                    .Max();

                return new LibraryAlbum
                {
                    Id = albumId,
                    Title = ordered[0].Album,
                    Artist = ordered[0].AlbumArtist,
                    Tracks = ordered,
                    Cover = covers.TryGetValue(albumId, out var cover) ? cover : null,
                    AddedAt = new DateTimeOffset(DateTime.SpecifyKind(modified, DateTimeKind.Utc)),
                    Year = ordered.Select(t => t.Year).FirstOrDefault(y => !string.IsNullOrWhiteSpace(y)),
                    Source = ordered[0].Source
                };
            })
            .OrderBy(a => a.Title, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static string AlbumId(string artist, string album) =>
        $"{artist.Trim().ToLowerInvariant()}\u001F{album.Trim().ToLowerInvariant()}";

    private sealed record Scanned(LibraryTrack Track, byte[]? Cover);

    public static async Task<LibraryScanBatch?> ScanFileAsync(Uri uri, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var scanned = await Task.Run(() => Scan(uri), cancellationToken).ConfigureAwait(false);
        if (scanned is null) return null;
        var covers = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var albumId = AlbumId(scanned.Track.AlbumArtist, scanned.Track.Album);
        if (scanned.Cover is { Length: > 0 }) covers[albumId] = scanned.Cover;
        return new LibraryScanBatch(new[] { scanned.Track }, covers);
    }

    public static bool IsSupportedAudioFile(string path) => AudioExtensions.Contains(Path.GetExtension(path));

    private static Scanned? Scan(Uri uri)
    {
        try
        {
            using var file = TagLib.File.Create(uri.LocalPath);
            var tag = file.Tag;
            var name = Path.GetFileNameWithoutExtension(uri.LocalPath);
            var artist = FirstNonEmpty(tag.Performers) ?? "Unknown Artist";
            var albumArtist = FirstNonEmpty(tag.AlbumArtists) ?? artist;
            var album = string.IsNullOrWhiteSpace(tag.Album)
                ? new DirectoryInfo(Path.GetDirectoryName(uri.LocalPath) ?? string.Empty).Name
                : tag.Album;

            var sidecar = Path.ChangeExtension(uri.LocalPath, ".lrc");
            var hasLyrics = IOFile.Exists(sidecar) || !string.IsNullOrWhiteSpace(tag.Lyrics);

            byte[]? cover = null;
            var picture = tag.Pictures
                ?.FirstOrDefault(p => p.Type == PictureType.FrontCover)
                ?? tag.Pictures?.FirstOrDefault();
            if (picture is not null)
                cover = picture.Data.Data;

            // Match the common desktop-player convention used by FLACintosh
            // projects: when no embedded art exists, look next to the record.
            cover ??= ReadFolderArtwork(Path.GetDirectoryName(uri.LocalPath));

            var track = new LibraryTrack
            {
                Id = uri,
                Title = string.IsNullOrWhiteSpace(tag.Title) ? name : tag.Title,
                Artist = artist,
                AlbumArtist = albumArtist,
                Album = string.IsNullOrWhiteSpace(album) ? "Unknown Album" : album,
                TrackNumber = tag.Track > 0 ? checked((int)tag.Track) : null,
                DiscNumber = tag.Disc > 0 ? checked((int)tag.Disc) : null,
                Duration = file.Properties.Duration.TotalSeconds,
                Year = tag.Year > 0 ? tag.Year.ToString() : null,
                HasLyrics = hasLyrics,
                EmbeddedLyrics = string.IsNullOrWhiteSpace(tag.Lyrics) ? null : tag.Lyrics,
                Source = LibrarySource.Folder
            };

            return new Scanned(track, cover);
        }
        catch
        {
            // One corrupt/incomplete file should not abort a 10,000-track scan.
            return null;
        }
    }

    private static string? FirstNonEmpty(string[]? values) =>
        values?.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim();

    private static byte[]? ReadFolderArtwork(string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory)) return null;

        foreach (var name in new[] { "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png", "front.jpg", "front.png" })
        {
            var path = Path.Combine(directory, name);
            try
            {
                if (IOFile.Exists(path)) return IOFile.ReadAllBytes(path);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        return null;
    }


}
