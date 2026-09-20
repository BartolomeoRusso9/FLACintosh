using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;
using MusicPlayerWin.Core.History;

namespace MusicPlayerWin.App.Views;

public sealed partial class HistoryPage : Page
{
    private sealed record DailyRow(string DateLabel, double Minutes)
    {
        public string MinutesLabel => $"{Minutes:0} min";
    }

    private sealed record TrackRow(string Title, string Artist, string Label)
    {
        public override string ToString() => Label;
    }

    private sealed record AlbumRow(string Name, int Plays, BitmapImage? Cover)
    {
        public string PlaysLabel => Plays == 1 ? "1 play" : $"{Plays} plays";
    }

    private bool _refreshing;

    public HistoryPage()
    {
        InitializeComponent();
        PeriodCombo.SelectedIndex = 0;
        Loaded += async (_, _) => await RefreshAsync();
        App.Services.PlayerStateChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.PlayerStateChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(async () => await RefreshAsync());

    private async void PeriodCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refreshing) return;
        await RefreshAsync();
    }

    private RecapPeriod Period => PeriodCombo.SelectedIndex switch
    {
        1 => RecapPeriod.Year,
        2 => RecapPeriod.All,
        _ => RecapPeriod.Month
    };

    private async void ClearHistory_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Clear listening history?", Content = "This removes local listening history and cannot be undone.", PrimaryButtonText = "Clear", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await App.Services.ClearHistoryAsync();
    }

    private async Task RefreshAsync()
    {
        _refreshing = true;
        var period = Period;
        var summary = App.Services.SummaryFor(period);
        Summary.Text = $"{summary.Plays} plays · {summary.Minutes:0} minutes heard";

        HeroSubtitle.Text = period switch
        {
            RecapPeriod.Month => "Your last 30 days in music",
            RecapPeriod.Year => $"Your {DateTime.Now.Year} in music",
            _ => "Your all time in music"
        };
        HeroMinutes.Text = ((int)Math.Round(summary.Minutes)).ToString();
        HeroCounts.Text = $"{summary.Plays} plays · {summary.TopTracks.Count} songs · {summary.TopArtists.Count} artists";

        var streak = App.Services.LongestStreakDays(period);
        StreakTitle.Text = streak == 1 ? "1 day in a row" : $"{streak} days in a row";
        StreakDetail.Text = "Your longest run of consecutive listening days.";
        var busiest = App.Services.BusiestDay(period);
        BusiestTitle.Text = busiest is { } b ? $"{b.Date:ddd d MMM}" : "No busiest day yet";
        BusiestDetail.Text = busiest is { } bd ? $"Your biggest day, with {bd.Minutes:0} minutes." : "";

        ArtistsList.ItemsSource = summary.TopArtists.Select(x => $"{x.Name} · {x.Plays}").ToArray();
        var albumRows = new List<AlbumRow>();
        foreach (var x in summary.TopAlbums) albumRows.Add(new AlbumRow(x.Name, x.Plays, await FindAlbumCoverAsync(x.Name)));
        AlbumsList.ItemsSource = albumRows;
        TracksList.ItemsSource = summary.TopTracks.Select(x => new TrackRow(x.Title, x.Artist, $"{x.Title} — {x.Artist} · {x.Plays}")).ToArray();

        RecentList.ItemsSource = App.Services.RecentListening;
        var daily = App.Services.ListeningDays.Select(x => new DailyRow(x.Date.ToString("ddd d MMM"), x.Minutes)).ToArray();
        DailyList.ItemsSource = daily;

        RefreshHourlyClock(App.Services.HoursOfDay(period));
        _refreshing = false;
    }

    private void RefreshHourlyClock(int[] hours)
    {
        HourlyClock.Children.Clear();
        var peak = Math.Max(1, hours.Length == 0 ? 1 : hours.Max());
        for (var hour = 0; hour < hours.Length; hour++)
        {
            var bar = new Border
            {
                Width = 6,
                CornerRadius = new CornerRadius(2),
                Background = hours[hour] == peak
                    ? new SolidColorBrush(Microsoft.UI.Colors.OrangeRed)
                    : new SolidColorBrush(Microsoft.UI.Colors.Gray) { Opacity = 0.35 },
                Height = Math.Max(3, 90.0 * hours[hour] / peak),
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(1, 0, 1, 0)
            };
            HourlyClock.Children.Add(bar);
        }
    }

    private static async Task<BitmapImage?> FindAlbumCoverAsync(string albumName)
    {
        var album = App.Services.Library.Albums.FirstOrDefault(a => string.Equals(a.Title, albumName, StringComparison.OrdinalIgnoreCase));
        return album?.Cover is { Length: > 0 } cover ? await BitmapFromBytesAsync(cover) : null;
    }

    private static async Task<BitmapImage> BitmapFromBytesAsync(byte[] data)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(data.AsBuffer());
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }

    private async void TracksList_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not TrackRow track) return;
        var match = App.Services.Library.Tracks.FirstOrDefault(t =>
            string.Equals(t.Title, track.Title, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(t.Artist, track.Artist, StringComparison.OrdinalIgnoreCase));
        if (match is not null) await App.Services.Playback.PlayAsync([match], 0);
    }
}
