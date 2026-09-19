using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class DownloadsPage : Page
{
    private sealed record ActiveRow(string Title, string Artist, int Done, int Total, string ProgressText);
    public DownloadsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.Offline.Changed += OfflineOnChanged;
        Unloaded += (_, _) => App.Services.Offline.Changed -= OfflineOnChanged;
    }

    private void OfflineOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var albums = App.Services.Offline.Albums;
        DownloadsList.ItemsSource = albums;
        EmptyState.Visibility = albums.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var active = App.Services.ActiveOfflineDownloads.Select(p =>
        {
            var album = App.Services.Library.Albums.FirstOrDefault(a => a.Id == p.Key);
            return new ActiveRow(album?.Title ?? p.Key, album?.Artist ?? "Downloading", p.Value.Done, p.Value.Total, $"{p.Value.Done}/{p.Value.Total}");
        }).ToArray();
        ActiveDownloadsList.ItemsSource = active;
        ActiveDownloadsList.Visibility = active.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Summary.Text = $"{albums.Count} albums · {FormatBytes(App.Services.Offline.SizeBytes)}" + (active.Length > 0 ? $" · {active.Length} downloading" : "");
    }

    private async void Play_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is LibraryAlbum album)
            await App.Services.PlayAlbumAsync(album);
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is LibraryAlbum album)
        {
            App.Services.Offline.Remove(album);
            Refresh();
        }
    }

    private async void RemoveAll_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Remove all downloads?",
            Content = "The local offline copies will be deleted.",
            PrimaryButtonText = "Remove all",
            CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            App.Services.Offline.RemoveAll();
            Refresh();
        }
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var index = 0;
        while (value >= 1024 && index < units.Length - 1) { value /= 1024; index++; }
        return $"{value:0.##} {units[index]}";
    }
}
