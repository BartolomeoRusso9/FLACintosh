using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class SearchPage : Page
{
    private readonly string _query;

    public SearchPage(string query)
    {
        _query = query;
        InitializeComponent();
        Heading.Text = $"Search results for “{query}”";
        Loaded += (_, _) => Refresh();
    }

    private void Refresh()
    {
        var library = App.Services.Library;
        var songs = library.SearchTracks(_query);
        var albums = library.SearchAlbums(_query);
        var artists = library.SearchArtists(_query);
        SongsList.ItemsSource = songs;
        AlbumsList.ItemsSource = albums;
        ArtistsList.ItemsSource = artists;
        EmptyState.Visibility = songs.Count == 0 && albums.Count == 0 && artists.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Song_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not LibraryTrack track) return;
        var songs = App.Services.Library.Songs;
        var index = Array.FindIndex(songs.ToArray(), x => x.Key == track.Key);
        if (index >= 0) await App.Services.Playback.PlayAsync(songs, index);
    }

    private void Album_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryAlbum album) App.MainWindow.ShowAlbum(album);
    }

    private void Artist_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryArtist artist) App.MainWindow.ShowArtist(artist);
    }
}
