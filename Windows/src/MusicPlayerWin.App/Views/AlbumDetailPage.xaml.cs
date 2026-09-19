using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class AlbumDetailPage : Page
{
    private readonly LibraryAlbum _album;

    public AlbumDetailPage(LibraryAlbum album)
    {
        _album = album;
        InitializeComponent();
        Loaded += async (_, _) => await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        Title.Text = _album.Title;
        Artist.Text = _album.Artist;
        Meta.Text = $"{_album.Tracks.Count} songs · {FormatDuration(_album.Duration)}" + (_album.Year is { Length: > 0 } ? $" · {_album.Year}" : "");
        TracksList.ItemsSource = _album.Tracks;
        if (_album.Cover is { Length: > 0 } cover)
            Artwork.Source = await BitmapFromBytesAsync(cover);
    }

    private async void Track_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryTrack track)
        {
            var index = _album.Tracks.ToList().FindIndex(x => x.Key == track.Key);
            if (index >= 0) await App.Services.Playback.PlayAsync(_album.Tracks, index);
        }
    }

    private async void Play_Click(object sender, RoutedEventArgs e) => await App.Services.PlayAlbumAsync(_album);

    private async void Shuffle_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Playback.Queue.IsShuffling = true;
        await App.Services.PlayAlbumAsync(_album);
    }

    private void Download_Click(object sender, RoutedEventArgs e)
    {
        if (!_album.Source.IsFolder) App.Services.Offline.Download(_album);
    }

    private void Back_Click(object sender, RoutedEventArgs e) => App.MainWindow.GoBackOrHome();

    private static async Task<BitmapImage> BitmapFromBytesAsync(byte[] data)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(data.AsBuffer());
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }

    private static string FormatDuration(double duration)
    {
        var ts = TimeSpan.FromSeconds(Math.Max(0, duration));
        return ts.TotalHours >= 1 ? ts.ToString(@"h\:mm\:ss") : ts.ToString(@"m\:ss");
    }
}
