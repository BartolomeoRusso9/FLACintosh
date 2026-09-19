using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class ArtistsPage : Page
{
    public ArtistsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.LibraryChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.LibraryChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var artists = App.Services.Library.Artists;
        ArtistsList.ItemsSource = artists;
        EmptyState.Visibility = artists.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void ArtistsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not LibraryArtist artist) return;
        App.MainWindow.ShowArtist(artist);
    }
}
