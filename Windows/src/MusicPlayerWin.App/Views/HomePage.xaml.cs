using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;
using MusicPlayerWin.Core.Library;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MusicPlayerWin.App.Views;

public sealed partial class HomePage : Page
{
    private sealed record SourceRow(string Key, string Name, string Detail, bool IsVisible);
    public HomePage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.LibraryChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.LibraryChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    public void Refresh()
    {
        var albums = App.Services.Library.Albums;
        AlbumsGrid.ItemsSource = albums;
        EmptyState.Visibility = albums.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        var library = App.Services.Library;
        LibrarySummary.Text = App.Services.IsScanning
            ? $"Scanning… {App.Services.ScanCompleted} / {App.Services.ScanTotal} files"
            : $"{library.Tracks.Count} songs · {library.Albums.Count} albums · {library.Artists.Count} artists";

        ScanProgress.Visibility = App.Services.IsScanning ? Visibility.Visible : Visibility.Collapsed;
        ScanProgress.Value = App.Services.ScanTotal > 0
            ? (double)App.Services.ScanCompleted / App.Services.ScanTotal
            : 0;

        SourcesList.ItemsSource = App.Services.Sources.Select(source => new SourceRow(
            source.Key,
            source.IsFolder ? "Local Music" : App.Services.Servers.Find(source.ServerId!.Value)?.Name ?? "Server",
            source.IsFolder ? (library.RootPath ?? "Choose a library folder") : $"{App.Services.Library.Tracks.Count(t => t.Source.Key == source.Key)} songs",
            !library.IsHidden(source))).ToArray();
    }

    private void SourceVisibility_Toggled(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleSwitch toggle || toggle.Tag is not string key) return;
        LibrarySource? source = App.Services.Sources.Where(x => string.Equals(x.Key, key, StringComparison.OrdinalIgnoreCase)).Select(x => (LibrarySource?)x).FirstOrDefault();
        if (source is not { } value) return;
        App.Services.SetSourceHidden(value, !toggle.IsOn);
        Refresh();
    }

    private async void ChooseFolderButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.MusicLibrary
        };
        picker.FileTypeFilter.Add("*");

        var hwnd = WindowNative.GetWindowHandle(App.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
            await App.Services.ScanFolderAsync(folder.Path);
    }

    private async void AlbumArtwork_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Image image || image.DataContext is not LibraryAlbum album) return;
        if (album.Cover is not { Length: > 0 } cover) return;

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

    private async void PlayAllButton_Click(object sender, RoutedEventArgs e)
    {
        await App.Services.PlayAllAsync();
    }

    private async void AlbumsGrid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryAlbum album)
            await App.Services.PlayAlbumAsync(album);
    }
}
