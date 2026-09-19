using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Metadata;
using System.Diagnostics;

namespace MusicPlayerWin.App.Views;

public sealed partial class SongsPage : Page
{
    private readonly AudioMetadataEditor _metadata = new();

    public SongsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.LibraryChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.LibraryChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var songs = App.Services.Library.Songs;
        SongsList.ItemsSource = songs;
        EmptyState.Visibility = songs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void SongsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not LibraryTrack track) return;
        var songs = App.Services.Library.Songs;
        var index = Array.FindIndex(songs.ToArray(), x => x.Key == track.Key);
        if (index >= 0)
            await App.Services.Playback.PlayAsync(songs, index);
    }

    private async void EditTags_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not LibraryTrack track || !track.Url.IsFile)
            return;

        AudioMetadataFields fields;
        try
        {
            fields = await Task.Run(() => _metadata.Read(track.Url));
        }
        catch (Exception ex)
        {
            await ShowErrorAsync("Could not read tags", ex.Message);
            return;
        }

        var title = new TextBox { Header = "Title", Text = fields.Title };
        var artist = new TextBox { Header = "Artist", Text = fields.Artist };
        var albumArtist = new TextBox { Header = "Album Artist", Text = fields.AlbumArtist };
        var album = new TextBox { Header = "Album", Text = fields.Album };
        var genre = new TextBox { Header = "Genre", Text = fields.Genre };
        var year = new TextBox { Header = "Year", Text = fields.Year };
        var trackNumber = new TextBox { Header = "Track", Text = fields.TrackNumber };
        var discNumber = new TextBox { Header = "Disc", Text = fields.DiscNumber };
        var form = new Grid { ColumnSpacing = 10, RowSpacing = 8 };
        TextBox[] fieldsForRows = [title, artist, albumArtist, album, genre];
        foreach (var box in fieldsForRows)
        {
            form.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            form.Children.Add(box);
            Grid.SetRow(box, form.RowDefinitions.Count - 1);
            Grid.SetColumnSpan(box, 2);
        }
        form.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var numbers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        numbers.Children.Add(year);
        numbers.Children.Add(trackNumber);
        numbers.Children.Add(discNumber);
        Grid.SetRow(numbers, form.RowDefinitions.Count - 1);
        Grid.SetColumnSpan(numbers, 2);
        form.Children.Add(numbers);

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Get Info",
            Content = new ScrollViewer { Content = form, MaxHeight = 620 },
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var updated = new AudioMetadataFields(title.Text, artist.Text, albumArtist.Text, album.Text, genre.Text, year.Text, trackNumber.Text, discNumber.Text);
        try
        {
            await Task.Run(() => _metadata.Write(track.Url, updated));
            // The file changed on disk. Rescan is the authoritative refresh, matching FLACintosh.
            var root = App.Services.Library.RootPath;
            if (!string.IsNullOrWhiteSpace(root)) await App.Services.ScanFolderAsync(root);
        }
        catch (Exception ex)
        {
            await ShowErrorAsync("Could not save tags", ex.Message);
        }
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not LibraryTrack track || !track.Url.IsFile) return;
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{track.Url.LocalPath.Replace("\"", "")}\"") { UseShellExecute = true }); } catch { }
    }

    private async Task ShowErrorAsync(string title, string message) =>
        await new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = message, CloseButtonText = "OK" }.ShowAsync();
}
