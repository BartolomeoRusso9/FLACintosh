using System.Text.Json;
using MusicPlayerWin.Core.Infrastructure;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.Core.History;

public sealed record ListenRecord(
    DateTimeOffset StartedAt,
    string TrackKey,
    string Title,
    string Artist,
    string Album,
    double DurationSeconds,
    double HeardSeconds);

public sealed record ListeningSummary(
    int Plays,
    double Minutes,
    IReadOnlyList<(string Name, int Plays)> TopArtists,
    IReadOnlyList<(string Name, int Plays)> TopAlbums,
    IReadOnlyList<(string Title, string Artist, int Plays)> TopTracks);

public sealed record ListeningDay(DateOnly Date, int Plays, double Minutes);

/// <summary>Windows counterpart of ListeningRecap.Period in ListeningHistory.swift.</summary>
public enum RecapPeriod { Month, Year, All }

public sealed class ListeningHistoryStore
{
    private readonly object _gate = new();
    private readonly string _path;
    private ListenRecord? _current;
    private DateTimeOffset _startedAt;
    private double _heardSeconds;

    public ListeningHistoryStore(string? applicationDataRoot = null)
    {
        var root = applicationDataRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(root);
        _path = Path.Combine(root, "history.jsonl");
    }

    public event Action<ListenRecord>? PlayRecorded;

    public void Start(LibraryTrack track)
    {
        lock (_gate)
        {
            FinalizeLocked();
            _startedAt = DateTimeOffset.UtcNow;
            _heardSeconds = 0;
            _current = new ListenRecord(_startedAt, track.Key, track.Title, track.Artist, track.Album, track.Duration ?? 0, 0);
        }
    }

    public void Accumulate(double seconds)
    {
        if (seconds <= 0 || seconds > 3) return;
        lock (_gate) _heardSeconds += seconds;
    }

    public void Finish()
    {
        lock (_gate) FinalizeLocked();
    }

    public ListeningSummary Summary() => SummarySince(DateTimeOffset.MinValue);

    public ListeningSummary SummarySince(DateTimeOffset since)
    {
        var valid = ReadAll().Where(x => x.StartedAt >= since && IsValidPlay(x)).ToArray();
        return new ListeningSummary(
            valid.Length,
            valid.Sum(x => x.HeardSeconds) / 60,
            valid.GroupBy(x => x.Artist, StringComparer.OrdinalIgnoreCase).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.OrdinalIgnoreCase).Take(10).Select(g => (g.Key, g.Count())).ToArray(),
            valid.GroupBy(x => x.Album, StringComparer.OrdinalIgnoreCase).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.OrdinalIgnoreCase).Take(10).Select(g => (g.Key, g.Count())).ToArray(),
            valid.GroupBy(x => x.TrackKey).OrderByDescending(g => g.Count()).ThenBy(g => g.First().Title, StringComparer.OrdinalIgnoreCase).Take(10).Select(g => (g.First().Title, g.First().Artist, g.Count())).ToArray());
    }

    public IReadOnlyList<ListeningDay> Daily(DateTimeOffset since)
    {
        return ReadAll().Where(IsValidPlay).Where(x => x.StartedAt >= since)
            .GroupBy(x => DateOnly.FromDateTime(x.StartedAt.ToLocalTime().DateTime))
            .OrderBy(x => x.Key)
            .Select(g => new ListeningDay(g.Key, g.Count(), g.Sum(x => x.HeardSeconds) / 60))
            .ToArray();
    }

    public IReadOnlyList<ListenRecord> Recent(int count = 50) => ReadAll().OrderByDescending(x => x.StartedAt).Take(Math.Max(1, count)).ToArray();

    private static bool InPeriod(DateTimeOffset date, RecapPeriod period, DateTimeOffset now) => period switch
    {
        RecapPeriod.Month => date > now.AddDays(-30),
        RecapPeriod.Year => date.ToLocalTime().Year == now.ToLocalTime().Year,
        _ => true
    };

    public ListeningSummary SummaryForPeriod(RecapPeriod period, DateTimeOffset? now = null)
    {
        var reference = now ?? DateTimeOffset.UtcNow;
        var valid = ReadAll().Where(x => IsValidPlay(x) && InPeriod(x.StartedAt, period, reference)).ToArray();
        return new ListeningSummary(
            valid.Length,
            valid.Sum(x => x.HeardSeconds) / 60,
            valid.GroupBy(x => x.Artist, StringComparer.OrdinalIgnoreCase).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.OrdinalIgnoreCase).Take(5).Select(g => (g.Key, g.Count())).ToArray(),
            valid.GroupBy(x => x.Album, StringComparer.OrdinalIgnoreCase).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.OrdinalIgnoreCase).Take(5).Select(g => (g.Key, g.Count())).ToArray(),
            valid.GroupBy(x => x.TrackKey).OrderByDescending(g => g.Count()).ThenBy(g => g.First().Title, StringComparer.OrdinalIgnoreCase).Take(5).Select(g => (g.First().Title, g.First().Artist, g.Count())).ToArray());
    }

    /// <summary>Plays in each hour of the day, 0…23, local time.</summary>
    public int[] HoursOfDay(RecapPeriod period, DateTimeOffset? now = null)
    {
        var reference = now ?? DateTimeOffset.UtcNow;
        var hours = new int[24];
        foreach (var record in ReadAll().Where(x => IsValidPlay(x) && InPeriod(x.StartedAt, period, reference)))
            hours[record.StartedAt.ToLocalTime().Hour]++;
        return hours;
    }

    public (DateOnly Date, double Minutes)? BusiestDay(RecapPeriod period, DateTimeOffset? now = null)
    {
        var reference = now ?? DateTimeOffset.UtcNow;
        var days = ReadAll().Where(x => IsValidPlay(x) && InPeriod(x.StartedAt, period, reference))
            .GroupBy(x => DateOnly.FromDateTime(x.StartedAt.ToLocalTime().DateTime))
            .Select(g => (Date: g.Key, Minutes: g.Sum(x => x.HeardSeconds) / 60))
            .ToArray();
        if (days.Length == 0) return null;
        return days.OrderByDescending(x => x.Minutes).First();
    }

    public int LongestStreakDays(RecapPeriod period, DateTimeOffset? now = null)
    {
        var reference = now ?? DateTimeOffset.UtcNow;
        var days = ReadAll().Where(x => IsValidPlay(x) && InPeriod(x.StartedAt, period, reference))
            .Select(x => DateOnly.FromDateTime(x.StartedAt.ToLocalTime().DateTime))
            .Distinct().OrderBy(x => x).ToArray();
        var longest = 0;
        var run = 0;
        DateOnly? previous = null;
        foreach (var day in days)
        {
            run = previous is { } p && day.DayNumber - p.DayNumber == 1 ? run + 1 : 1;
            longest = Math.Max(longest, run);
            previous = day;
        }
        return longest;
    }

    public void Clear()
    {
        lock (_gate)
        {
            _current = null;
            _heardSeconds = 0;
            AtomicFile.WriteAllText(_path, string.Empty);
        }
    }

    public void Flush() { lock (_gate) FinalizeLocked(); }

    public static bool IsValidPlay(ListenRecord record) => record.DurationSeconds >= 30 && (record.HeardSeconds >= record.DurationSeconds / 2 || record.HeardSeconds >= 240);

    public IReadOnlyList<ListenRecord> ReadAll()
    {
        lock (_gate)
        {
            var result = new List<ListenRecord>();
            if (File.Exists(_path))
            {
                foreach (var line in File.ReadLines(_path))
                {
                    try { if (JsonSerializer.Deserialize<ListenRecord>(line) is { } record) result.Add(record); } catch { }
                }
            }
            if (_current is not null) result.Add(_current with { StartedAt = _startedAt, HeardSeconds = _heardSeconds });
            return result;
        }
    }

    private void FinalizeLocked()
    {
        if (_current is null) return;
        var record = _current with { StartedAt = _startedAt, HeardSeconds = _heardSeconds };
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.AppendAllText(_path, JsonSerializer.Serialize(record) + Environment.NewLine);
        _current = null;
        _heardSeconds = 0;
        if (IsValidPlay(record)) PlayRecorded?.Invoke(record);
    }
}
