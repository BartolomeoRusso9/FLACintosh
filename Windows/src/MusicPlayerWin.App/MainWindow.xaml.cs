using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Windowing;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;
using Windows.ApplicationModel.DataTransfer;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Playback;
using MusicPlayerWin.App.Views;
using MusicPlayerWin.App.Services;
using WinRT.Interop;
using DragEventArgs = Microsoft.UI.Xaml.DragEventArgs;

namespace MusicPlayerWin.App;

public sealed partial class MainWindow : Window
{
    private readonly DispatcherQueueTimer _timer;
    private bool _changingSlider;
    private bool _changingVolume;
    private readonly TrayService _tray;

    internal async Task ShowFirstRunAsync()
    {
        var choose = new CheckBox { Content = "Choose a local music folder now", IsChecked = !string.IsNullOrWhiteSpace(App.Services.Library.RootPath) };
        var info = new StackPanel { Spacing = 10 };
        info.Children.Add(new TextBlock { Text = "Welcome to MusicPlayerWin", FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        info.Children.Add(new TextBlock { Text = "Windows counterpart of FLACintosh. You can start with a local folder or configure servers later in Settings.", TextWrapping = TextWrapping.Wrap });
        info.Children.Add(choose);
        var dialog = new ContentDialog
        { XamlRoot = Content.XamlRoot, Title = "First launch", Content = info, PrimaryButtonText = "Continue", CloseButtonText = "Skip" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && choose.IsChecked == true)
        {
            var picker = new Windows.Storage.Pickers.FolderPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.MusicLibrary };
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is not null) await App.Services.ScanFolderAsync(folder.Path);
        }
        App.FirstRun.MarkComplete();
    }

    public MainWindow()
    {
        InitializeComponent();
        RootGrid.KeyDown += MainWindow_KeyDown;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 820));

        Navigation.SelectedItem = Navigation.MenuItems[0];
        ContentFrame.Content = new HomePage();

        App.Services.PlayerStateChanged += ServicesOnChanged;
        App.Services.LibraryChanged += ServicesOnChanged;
        App.Services.ErrorRaised += ServicesOnError;
        _tray = new TrayService(ShowFromTray, () => App.Services.Playback.TogglePlayPause(), async () => await App.Services.Playback.NextAsync(), async () => await App.Services.Playback.PreviousAsync(), RequestExit, Path.Combine(AppContext.BaseDirectory, "Assets", "MusicPlayerWin.ico"));

        AppWindow.Closing += AppWindow_Closing;
        Closed += MainWindow_Closed;

        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(250);
        _timer.Tick += (_, _) => RefreshTransport();
        _timer.Start();
        ApplyTheme();
        RefreshTransport();
    }

    private void ApplyTheme()
    {
        RootGrid.RequestedTheme = App.Services.Settings.Theme switch
        {
            "Light" => ElementTheme.Light,
            "Dark" => ElementTheme.Dark,
            _ => ElementTheme.Default
        };
    }

    private void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is not string tag) return;
        ContentFrame.Content = tag switch
        {
            "home" => new HomePage(),
            "songs" => new SongsPage(),
            "albums" => new AlbumsPage(),
            "recent" => new RecentlyAddedPage(),
            "artists" => new ArtistsPage(),
            "now" => new NowPlayingPage(),
            "queue" => new QueuePage(),
            "playlists" => new PlaylistsPage(),
            "downloads" => new DownloadsPage(),
            "history" => new HistoryPage(),
            "spotiflac" => new SpotiFlacPage(),
            _ => new HomePage()
        };
    }



    private void GlobalSearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        var query = sender.Text?.Trim();
        if (string.IsNullOrWhiteSpace(query)) { sender.ItemsSource = null; return; }
        var tracks = App.Services.SearchTracks(query, 8).Select(t => $"{t.Title} — {t.Artist}");
        var albums = App.Services.SearchAlbums(query, 4).Select(a => $"Album: {a.Title} — {a.Artist}");
        sender.ItemsSource = tracks.Concat(albums).Take(12).ToArray();
    }

    private void GlobalSearchBox_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var query = args.QueryText?.Trim();
        if (string.IsNullOrWhiteSpace(query)) return;
        sender.ItemsSource = null;
        ContentFrame.Content = new SearchPage(query);
    }

    private void ServicesOnError(object? sender, string message)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            GlobalErrorBar.Message = message;
            GlobalErrorBar.IsOpen = true;
        });
    }

    public void ShowAlbum(LibraryAlbum album) => ContentFrame.Content = new AlbumDetailPage(album);

    public void ShowArtist(LibraryArtist artist) => ContentFrame.Content = new ArtistDetailPage(artist);

    public void ShowPlaylist(MusicPlayerWin.Core.Playlists.Playlist playlist) => ContentFrame.Content = new PlaylistDetailPage(playlist);

    public void ShowSpotiFlacTracklist(Services.SpotiFlacResult result) => ContentFrame.Content = new SpotiFlacTracklistPage(result);

    public void GoBackOrHome() => ContentFrame.Content = new HomePage();


    private void ShowFromTray()
    {
        Activate();

    }

    private void Navigation_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.IsSettingsInvoked)
            ContentFrame.Content = new SettingsPage();
    }

    private void PlayPause_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Playback.TogglePlayPause();
        RefreshTransport();
    }

    private async void Previous_Click(object sender, RoutedEventArgs e)
    {
        await App.Services.Playback.PreviousAsync();
        RefreshTransport();
    }

    private async void Next_Click(object sender, RoutedEventArgs e)
    {
        await App.Services.Playback.NextAsync();
        RefreshTransport();
    }

    private void ProgressSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_changingSlider) return;
        App.Services.Playback.Seek(e.NewValue);
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(() => { ApplyTheme(); RefreshTransport(); });

    private void RefreshTransport()
    {
        var track = App.Services.Playback.CurrentTrack;
        var state = App.Services.Playback.Audio.State;

        NowTitle.Text = track?.Title ?? "Nothing playing";
        NowArtist.Text = track?.Artist ?? "";
        PlayPauseButton.Content = state.IsPlaying ? "Pause" : "Play";
        _ = LoadTransportArtworkAsync(track);

        _changingSlider = true;
        ProgressSlider.Maximum = Math.Max(1, state.Duration);
        ProgressSlider.Value = Math.Clamp(state.Position, 0, ProgressSlider.Maximum);
        ElapsedText.Text = FormatTime(state.Position);
        DurationText.Text = FormatTime(state.Duration);
        _changingSlider = false;

        _changingVolume = true;
        VolumeSlider.Value = Math.Clamp(state.Volume, 0, 1);
        _changingVolume = false;
        ShuffleButton.Content = App.Services.Playback.Queue.IsShuffling ? "Shuffle On" : "Shuffle";
        RepeatButton.Content = $"Repeat {App.Services.Playback.Queue.RepeatMode}";

        var hasLyrics = track?.HasLyrics == true;
        ToolTipService.SetToolTip(LyricsButton, hasLyrics ? "Lyrics" : "No lyrics for this track");

        if (App.Services.Cast.Connected && !string.IsNullOrWhiteSpace(App.Services.Cast.ReceiverHost))
        {
            CastButton.Content = $"Cast: {App.Services.Cast.ReceiverHost}";
            NowCastDevice.Text = $"· {App.Services.Cast.ReceiverHost}";
            NowCastDevice.Visibility = Visibility.Visible;
        }
        else
        {
            CastButton.Content = "Cast";
            NowCastDevice.Visibility = Visibility.Collapsed;
        }
    }

    private void Shuffle_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Playback.Queue.IsShuffling = !App.Services.Playback.Queue.IsShuffling;
        RefreshTransport();
    }

    private void Repeat_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Playback.Queue.RepeatMode = App.Services.Playback.Queue.RepeatMode.Next();
        RefreshTransport();
    }

    private void MainWindow_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(
            Windows.System.VirtualKey.Control) != Windows.UI.Core.CoreVirtualKeyStates.None;
        if (ctrl && e.Key == Windows.System.VirtualKey.K)
        {
            GlobalSearchBox.Focus(FocusState.Programmatic);
            e.Handled = true;
            return;
        }

        switch (e.Key)
        {
            case Windows.System.VirtualKey.Space:
                App.Services.Playback.TogglePlayPause();
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Left: e.Handled = true; App.Services.Playback.Seek(Math.Max(0, App.Services.Playback.Audio.State.Position - 5)); break;
            case Windows.System.VirtualKey.Right: e.Handled = true; App.Services.Playback.Seek(Math.Min(App.Services.Playback.Audio.State.Duration, App.Services.Playback.Audio.State.Position + 5)); break;
        }
    }

    private void Queue_Click(object sender, RoutedEventArgs e)
    {
        ContentFrame.Content = new QueuePage();
    }

    private void OpenNowPlaying_Click(object sender, RoutedEventArgs e) => ContentFrame.Content = new NowPlayingPage();

    private void Lyrics_Click(object sender, RoutedEventArgs e) => ContentFrame.Content = new NowPlayingPage();

    private void Cast_Click(object sender, RoutedEventArgs e) => ContentFrame.Content = new SettingsPage();

    private void VolumeSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_changingVolume) return;
        App.Services.Playback.SetVolume(e.NewValue);
    }

    private bool _shutdownRequested;
    private bool _forceClose;

    private void RequestExit()
    {
        _forceClose = true;
        Close();
    }

    private void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_forceClose || _shutdownRequested || !App.Services.Settings.MinimizeToTray) return;
        args.Cancel = true;
        sender.Hide();
        AppLog.Info("Main window hidden to tray.");
    }

    private async void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        App.Services.PlayerStateChanged -= ServicesOnChanged;
        App.Services.LibraryChanged -= ServicesOnChanged;
        App.Services.ErrorRaised -= ServicesOnError;
        AppWindow.Closing -= AppWindow_Closing;
        _tray.Dispose();
        _timer.Stop();
        if (!_shutdownRequested) _shutdownRequested = true;
        await App.ShutdownAsync();
    }

    private void RootGrid_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Play or add audio files";
    }

    private async void RootGrid_Drop(object sender, DragEventArgs e)
    {
        try
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            var files = items.Where(x => x is Windows.Storage.StorageFile)
                .Cast<Windows.Storage.StorageFile>()
                .Where(f => LibraryScanner.IsSupportedAudioFile(f.Path))
                .ToArray();
            if (files.Length == 0) return;

            if (files.Length == 1)
            {
                await App.Services.PlayFileAsync(files[0].Path);
                return;
            }

            var tracks = new List<LibraryTrack>();
            foreach (var file in files)
            {
                var track = App.Services.Library.Find(new Uri(Path.GetFullPath(file.Path)));
                if (track is null)
                {
                    var batch = await LibraryScanner.ScanFileAsync(new Uri(Path.GetFullPath(file.Path)));
                    track = batch?.Tracks.FirstOrDefault();
                }
                if (track is not null) { App.Services.Library.Add(track); tracks.Add(track); }
            }
            if (tracks.Count > 0) await App.Services.Playback.PlayAsync(tracks, 0);
        }
        catch (Exception ex)
        {
            AppLog.Error("Drag-and-drop failed.", ex);
            GlobalErrorBar.Message = ex.Message;
            GlobalErrorBar.IsOpen = true;
        }
    }

    private static string FormatTime(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "0:00";
        var span = TimeSpan.FromSeconds(seconds);
        return span.TotalHours >= 1 ? $"{(int)span.TotalHours}:{span.Minutes:00}:{span.Seconds:00}" : $"{span.Minutes}:{span.Seconds:00}";
    }

    private async Task LoadTransportArtworkAsync(LibraryTrack? track)
    {
        NowArtwork.Source = null;
        if (track is null) return;

        var album = App.Services.Library.Albums.FirstOrDefault(a => a.Tracks.Any(t => t.Key == track.Key));
        if (album?.Cover is not { Length: > 0 } cover) return;

        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(cover.AsBuffer());
            stream.Seek(0);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            NowArtwork.Source = bitmap;
        }
        catch
        {
            NowArtwork.Source = null;
        }
    }
}
