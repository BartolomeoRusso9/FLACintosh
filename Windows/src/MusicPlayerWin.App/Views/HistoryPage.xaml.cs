using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MusicPlayerWin.App.Views;

public sealed partial class HistoryPage : Page
{
    private sealed record DailyRow(string DateLabel, double Minutes)
    {
        public string MinutesLabel => $"{Minutes:0} min";
    }
    public HistoryPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.PlayerStateChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.PlayerStateChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private async void ClearHistory_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Clear listening history?", Content = "This removes local listening history and cannot be undone.", PrimaryButtonText = "Clear", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await App.Services.ClearHistoryAsync();
    }

    private void Refresh()
    {
        var summary = App.Services.ListeningSummary;
        Summary.Text = $"{summary.Plays} plays · {summary.Minutes:0} minutes heard";
        ArtistsList.ItemsSource = summary.TopArtists.Select(x => $"{x.Name} · {x.Plays}").ToArray();
        AlbumsList.ItemsSource = summary.TopAlbums.Select(x => $"{x.Name} · {x.Plays}").ToArray();
        TracksList.ItemsSource = summary.TopTracks.Select(x => $"{x.Title} — {x.Artist} · {x.Plays}").ToArray();
        RecentList.ItemsSource = App.Services.RecentListening;
        var daily = App.Services.ListeningDays.Select(x => new DailyRow(x.Date.ToString("ddd d MMM"), x.Minutes)).ToArray();
        DailyList.ItemsSource = daily;
    }
}
