using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using MusicPlayerWin.Core.Lyrics;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.App.Controls;
using Windows.Storage.Streams;
using Windows.Media.Core;
using MusicPlayerWin.App.Services;

namespace MusicPlayerWin.App.Views;

public sealed partial class NowPlayingPage : Page
{
    private readonly DispatcherQueueTimer _timer;
    private TimedLyrics? _lyrics;
    private int? _lastLine;

    public NowPlayingPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        App.Services.Playback.TrackChanged += PlaybackOnTrackChanged;
        App.Services.PlayerStateChanged += ServicesOnChanged;

        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(100);
        _timer.Tick += (_, _) => RefreshLyricsPosition();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _timer.Start();
        await LoadCurrentTrackAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _timer.Stop();
        try { CanvasPlayer.MediaPlayer?.Pause(); } catch { }
    }

    private void PlaybackOnTrackChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() => _ = LoadCurrentTrackAsync());
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(RefreshLyricsPosition);

    private async Task LoadCurrentTrackAsync()
    {
        var track = App.Services.Playback.CurrentTrack;
        Title.Text = track?.Title ?? "Nothing playing";
        Artist.Text = track?.Artist ?? "";
        Album.Text = track?.Album ?? "";

        ArtworkImage.Source = null;
        if (track is not null)
        {
            var album = App.Services.Library.Albums.FirstOrDefault(a => a.Tracks.Any(t => t.Key == track.Key));
            if (album?.Cover is { Length: > 0 } cover)
                ArtworkImage.Source = await BitmapFromBytesAsync(cover);
        }

        _lyrics = track is null ? null : await LyricsSidecar.LoadAsync(track.Url);
        if (_lyrics is null && !string.IsNullOrWhiteSpace(track?.EmbeddedLyrics))
            _lyrics = EnhancedLrc.Parse(track.EmbeddedLyrics);
        LyricsSource.Text = _lyrics is null
            ? "No synced lyrics"
            : File.Exists(Path.ChangeExtension(track!.Url.LocalPath, ".lrc"))
                ? "Local .lrc"
                : "Embedded lyrics";
        ConfigureCanvas(track);
        if (track is not null && (await TryPaletteAsync(track)) is PaletteColor palette)
            RootGrid.Background = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(80, palette.R, palette.G, palette.B));
        else
            RootGrid.Background = null;
        RebuildLyrics();
        RefreshLyricsPosition();
    }

    private void RebuildLyrics()
    {
        LyricsPanel.Children.Clear();
        _lastLine = null;

        if (_lyrics is null || _lyrics.IsEmpty) return;

        foreach (var line in _lyrics.Lines)
        {
            var row = new SyllableFlowPanel { Spacing = 2, Margin = new Thickness(0, 2, 0, 8) };
            foreach (var syllable in line.Syllables)
            {
                var text = new TextBlock
                {
                    Text = string.IsNullOrEmpty(syllable.Text) ? " " : syllable.Text,
                    FontSize = 18,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                    Opacity = 0.35
                };
                text.Tag = syllable;
                row.Children.Add(text);
            }
            row.Tag = line;
            LyricsPanel.Children.Add(row);
        }
    }

    private void RefreshLyricsPosition()
    {
        SyncCanvas();
        var time = App.Services.Playback.Audio.State.Position;
        var lineIndex = _lyrics?.LineIndex(time);
        if (_lyrics is null) return;

        for (var i = 0; i < LyricsPanel.Children.Count; i++)
        {
            if (LyricsPanel.Children[i] is not SyllableFlowPanel row || row.Tag is not LyricLine line) continue;
            var active = lineIndex == i;
            row.Opacity = active ? 1.0 : 0.55;
            foreach (var child in row.Children)
            {
                if (child is not TextBlock text || text.Tag is not Syllable syllable) continue;
                var progress = syllable.Progress(time);
                text.Opacity = active ? 0.3 + progress * 0.7 : 0.35;
            }
            if (active && _lastLine != lineIndex) row.StartBringIntoView();
        }
        _lastLine = lineIndex;
    }

    private void ConfigureCanvas(LibraryTrack? track)
    {
        CanvasPlayer.Visibility = Visibility.Collapsed;
        CanvasSource.Text = "";
        if (track is null) return;
        try
        {
            var path = track.Url.IsFile ? CanvasLocator.Find(track.Url.LocalPath) : null;
            if (path is null) return;
            CanvasPlayer.Source = MediaSource.CreateFromUri(new Uri(path));
            CanvasPlayer.Visibility = Visibility.Visible;
            CanvasSource.Text = "Canvas video";
            try { CanvasPlayer.MediaPlayer?.Pause(); CanvasPlayer.MediaPlayer!.Position = TimeSpan.Zero; } catch { }
        }
        catch { CanvasPlayer.Visibility = Visibility.Collapsed; }
    }

    private async Task<PaletteColor?> TryPaletteAsync(LibraryTrack track)
    {
        var album = App.Services.Library.Albums.FirstOrDefault(a => a.Tracks.Any(t => t.Key == track.Key));
        return album?.Cover is { Length: > 0 } cover ? await ArtworkPaletteService.ExtractAsync(cover) : null;
    }

    private void SyncCanvas()
    {
        var player = CanvasPlayer.MediaPlayer;
        if (player is null || CanvasPlayer.Visibility != Visibility.Visible) return;
        var audio = App.Services.Playback.Audio.State;
        try
        {
            if (Math.Abs(player.Position.TotalSeconds - audio.Position) > 1.0) player.Position = TimeSpan.FromSeconds(Math.Max(0, audio.Position));
            if (audio.IsPlaying) player.Play(); else player.Pause();
        }
        catch { }
    }

    private static async Task<BitmapImage> BitmapFromBytesAsync(byte[] data)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(data.AsBuffer());
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }
}
