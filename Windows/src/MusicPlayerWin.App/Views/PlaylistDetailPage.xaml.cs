using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Playlists;

namespace MusicPlayerWin.App.Views;

public sealed partial class PlaylistDetailPage : Page
{
    private Playlist? _playlist;
    private sealed record Row(int Position, int Index, PlaylistEntry Entry);

    public PlaylistDetailPage(Playlist playlist)
    {
        InitializeComponent();
        _playlist = playlist;
        Loaded += (_, _) => Refresh();
    }

    private void Refresh()
    {
        if (_playlist is null) return;
        _playlist = App.Services.Playlists.Find(_playlist.Id) ?? _playlist;
        Title.Text = _playlist.Name;
        Summary.Text = $"{_playlist.Entries.Count} tracks · modified {_playlist.Modified.LocalDateTime:g}";
        Tracks.ItemsSource = _playlist.Entries.Select((entry, index) => new Row(index + 1, index, entry)).ToArray();
    }

    private async void Play_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is not null) await App.Services.PlayPlaylistAsync(_playlist);
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is null || (sender as FrameworkElement)?.Tag is not int index) return;
        App.Services.Playlists.RemoveAt(_playlist.Id, [index]);
        Refresh();
    }

    private void Up_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is null || (sender as FrameworkElement)?.Tag is not int index || index <= 0) return;
        App.Services.Playlists.Move(_playlist.Id, index, index - 1);
        Refresh();
    }

    private void Down_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is null || (sender as FrameworkElement)?.Tag is not int index || index >= _playlist.Entries.Count - 1) return;
        App.Services.Playlists.Move(_playlist.Id, index, index + 1);
        Refresh();
    }

    private void AddQueue_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is null) return;
        var tracks = App.Services.Playback.Queue.Queue;
        App.Services.Playlists.Add(_playlist.Id, tracks);
        Refresh();
    }

    private async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is null) return;
        var box = new TextBox { Text = _playlist.Name };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Rename playlist", Content = box, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            App.Services.Playlists.Rename(_playlist.Id, box.Text);
            Refresh();
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_playlist is null) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Delete playlist?", Content = _playlist.Name, PrimaryButtonText = "Delete", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            App.Services.Playlists.Delete(_playlist.Id);
            App.Services.NotifyPlaylistsChanged();
            (App.MainWindow as MainWindow)?.GoBackOrHome();
        }
    }
}
