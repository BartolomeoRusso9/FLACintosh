using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Playlists;
using MusicPlayerWin.Core.Servers;

namespace MusicPlayerWin.App.Views;

public sealed partial class PlaylistsPage : Page
{
    public PlaylistsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.PlaylistsChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.PlaylistsChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var local = App.Services.Playlists.Playlists;
        var remote = App.Services.ServerPlaylists;
        PlaylistsList.ItemsSource = local;
        ServerPlaylistsList.ItemsSource = remote;
        EmptyState.Visibility = local.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyServerState.Visibility = remote.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Create_Click(object sender, RoutedEventArgs e)
    {
        var box = new TextBox { PlaceholderText = "Playlist name" };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "New playlist",
            Content = box,
            PrimaryButtonText = "Create",
            CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        App.Services.Playlists.Create(string.IsNullOrWhiteSpace(box.Text) ? null : box.Text);
        Refresh();
    }

    private async void Playlist_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is Playlist playlist)
            App.MainWindow.ShowPlaylist(playlist);
    }

    private async void Play_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Playlist playlist)
            await App.Services.PlayPlaylistAsync(playlist);
    }

    private async void ServerPlaylist_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ServerPlaylist playlist)
            await App.Services.PlayServerPlaylistAsync(playlist);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not Playlist playlist) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Delete playlist?",
            Content = playlist.Name,
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            App.Services.Playlists.Delete(playlist.Id);
            Refresh();
        }
    }
}
