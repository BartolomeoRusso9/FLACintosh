using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

public sealed partial class QueuePage : Page
{
    private sealed record QueueItem(int Position, LibraryTrack Track, int QueueIndex)
    {
        public bool IsCurrent => Position == 0;
    }

    public QueuePage()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
        App.Services.PlayerStateChanged += ServicesOnChanged;
        Unloaded += (_, _) => App.Services.PlayerStateChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        var queue = App.Services.Playback.Queue;
        var items = new List<QueueItem>();
        if (queue.CurrentTrack is { } current && queue.CurrentIndex is int currentIndex)
            items.Add(new QueueItem(0, current, currentIndex));
        var next = queue.UpNextIndices;
        for (var i = 0; i < next.Count; i++) items.Add(new QueueItem(i + 1, queue.Queue[next[i]], next[i]));
        QueueList.ItemsSource = items;
        Summary.Text = items.Count == 0 ? "Nothing queued" : $"{items.Count} track{(items.Count == 1 ? "" : "s")} · {(queue.IsShuffling ? "Shuffle" : "In order")} · Repeat {queue.RepeatMode}";
    }

    private async void Queue_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is QueueItem item)
            await App.Services.Playback.JumpAsync(item.QueueIndex);
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is int index)
            App.Services.Playback.Queue.RemoveNext(index);
        Refresh();
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is int index && App.Services.Playback.Queue.CurrentIndex is int current && index > current)
            App.Services.Playback.Queue.Move(index, index - 1);
        Refresh();
    }

    private void MoveDown_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is int index && App.Services.Playback.Queue.CurrentIndex is int current && index > current && index < App.Services.Playback.Queue.Queue.Count - 1)
            App.Services.Playback.Queue.Move(index, index + 1);
        Refresh();
    }

    private async void SavePlaylist_Click(object sender, RoutedEventArgs e)
    {
        var tracks = App.Services.Playback.Queue.Queue;
        if (tracks.Count == 0) return;
        var box = new TextBox { PlaceholderText = "Playlist name" };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Save queue as playlist", Content = box, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var playlist = App.Services.Playlists.Create(string.IsNullOrWhiteSpace(box.Text) ? null : box.Text, tracks);
        App.MainWindow.ShowPlaylist(playlist);
        App.Services.NotifyPlaylistsChanged();
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Playback.Queue.ClearQueue();
        Refresh();
    }
}
