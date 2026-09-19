using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class RecentlyAddedPage : Page
{
    public RecentlyAddedPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.LibraryChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.LibraryChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var recent = App.Services.Library.RecentlyAdded;
        RecentList.ItemsSource = recent;
        EmptyState.Visibility = recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void RecentList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LibraryAlbum album)
            await App.Services.PlayAlbumAsync(album);
    }
}
