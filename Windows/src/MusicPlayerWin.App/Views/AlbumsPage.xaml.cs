using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MusicPlayerWin.Core.Library;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

namespace MusicPlayerWin.App.Views;

public sealed partial class AlbumsPage : Page
{
    public AlbumsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.LibraryChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.LibraryChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var albums = App.Services.Library.Albums;
        AlbumsGrid.ItemsSource = albums;
        EmptyState.Visibility = albums.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void AlbumsGrid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryAlbum album)
            App.MainWindow.ShowAlbum(album);
    }

    private void Download_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is LibraryAlbum album && !album.Source.IsFolder)
            App.Services.Offline.Download(album);
    }

    private async void AlbumArtwork_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Image image || image.DataContext is not LibraryAlbum album || album.Cover is not { Length: > 0 } cover)
            return;

        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(cover.AsBuffer());
            stream.Seek(0);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            image.Source = bitmap;
        }
        catch
        {
            image.Source = null;
        }
    }
}
