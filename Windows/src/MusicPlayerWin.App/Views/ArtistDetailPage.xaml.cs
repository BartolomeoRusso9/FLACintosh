using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class ArtistDetailPage : Page
{
    private readonly LibraryArtist _artist;

    public ArtistDetailPage(LibraryArtist artist)
    {
        _artist = artist;
        InitializeComponent();
        Loaded += (_, _) => Refresh();
    }

    private void Refresh()
    {
        ArtistName.Text = _artist.Name;
        Meta.Text = $"{_artist.Albums.Count} albums · {_artist.TrackCount} songs";
        AlbumsList.ItemsSource = _artist.Albums;
    }

    private async void Play_Click(object sender, RoutedEventArgs e)
    {
        var tracks = _artist.Albums.SelectMany(a => a.Tracks).ToArray();
        if (tracks.Length > 0) await App.Services.Playback.PlayAsync(tracks, 0);
    }

    private void Album_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryAlbum album) App.MainWindow.ShowAlbum(album);
    }

    private void Back_Click(object sender, RoutedEventArgs e) => App.MainWindow.GoBackOrHome();
}
