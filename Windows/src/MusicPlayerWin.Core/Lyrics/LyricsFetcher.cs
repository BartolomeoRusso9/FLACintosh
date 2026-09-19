using System.Net.Http.Json;
using System.Net;
using System.Text.Json;

namespace MusicPlayerWin.Core.Lyrics;

public sealed class LyricsFetcher
{
    private readonly HttpClient _http;

    public LyricsFetcher(HttpClient? httpClient = null)
    {
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("MusicPlayerWin/0.2");
    }

    public async Task<string?> FetchAsync(
        string title,
        string artist,
        double durationSeconds,
        CancellationToken cancellationToken = default)
    {
        var query = Uri.EscapeDataString(title.Trim());
        var singer = Uri.EscapeDataString(artist.Trim());
        var url = new Uri($"https://lrclib.net/api/get?track_name={query}&artist_name={singer}&duration={Math.Round(durationSeconds)}");
        try
        {
            using var response = await _http.GetAsync(url, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.NotFound) return null;
            response.EnsureSuccessStatusCode();
            var result = await response.Content.ReadFromJsonAsync<LrcLibResponse>(cancellationToken: cancellationToken).ConfigureAwait(false);
            if (result is null) return null;
            if (!string.IsNullOrWhiteSpace(result.SyncedLyrics)) return result.SyncedLyrics;
            return string.IsNullOrWhiteSpace(result.PlainLyrics) ? null : result.PlainLyrics;
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
    }

    private sealed record LrcLibResponse(
        string? SyncedLyrics,
        string? PlainLyrics);
}
