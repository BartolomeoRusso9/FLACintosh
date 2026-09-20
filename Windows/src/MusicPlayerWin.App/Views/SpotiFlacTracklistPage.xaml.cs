using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MusicPlayerWin.App.Services;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Views;

/// <summary>
/// What a search result holds — an album's tracks, a playlist's, an
/// artist's records — read from the SpotiFLAC server, with the choice of
/// downloading all of it or only some. Windows counterpart of
/// RemoteTracklistView.swift.
/// </summary>
public sealed partial class SpotiFlacTracklistPage : Page
{
    private readonly SpotiFlacResult _result;
    private SpotiFlacTracklist? _tracklist;
    private int _selectedCount;

    public SpotiFlacTracklistPage(SpotiFlacResult result)
    {
        _result = result;
        InitializeComponent();
        TitleText.Text = result.Title;
        KindLabel.Text = result.Kind.ToUpperInvariant();
        SubtitleText.Text = result.Subtitle;
        Artwork.Source = CoverFrom(result.Cover);
        Loaded += async (_, _) => await LoadAsync();
        App.Services.SpotiFlacServer.DownloadsChanged += DownloadsOnChanged;
        Unloaded += (_, _) => App.Services.SpotiFlacServer.DownloadsChanged -= DownloadsOnChanged;
        RefreshDownloads();
    }

    private async Task LoadAsync()
    {
        LoadingPanel.Visibility = Visibility.Visible;
        ErrorPanel.Visibility = Visibility.Collapsed;
        FlatTracksList.Visibility = Visibility.Collapsed;
        DiscographyList.Visibility = Visibility.Collapsed;
        LoadingText.Text = _result.Kind == "artist" ? "Reading the discography — this can take a while" : "Reading the track list…";

        try
        {
            _tracklist = await App.Services.SpotiFlacServer.GetTracklistAsync(_result.Link);
            LoadingPanel.Visibility = Visibility.Collapsed;
            Populate(_tracklist);
        }
        catch (Exception ex)
        {
            LoadingPanel.Visibility = Visibility.Collapsed;
            ErrorPanel.Visibility = Visibility.Visible;
            ErrorText.Text = ex.Message;
        }
    }

    private void Populate(SpotiFlacTracklist list)
    {
        TitleText.Text = string.IsNullOrEmpty(list.Title) ? _result.Title : list.Title;
        if (list.Cover is { Length: > 0 } cover) Artwork.Source = CoverFrom(cover);
        SubtitleText.Text = _result.Kind switch
        {
            "artist" => "",
            "playlist" => string.IsNullOrEmpty(list.Owner) ? _result.Subtitle : list.Owner,
            _ => string.IsNullOrEmpty(list.Artist) ? _result.Subtitle : list.Artist
        };
        DescriptionText.Text = list.Description ?? "";
        DescriptionText.Visibility = string.IsNullOrEmpty(list.Description) ? Visibility.Collapsed : Visibility.Visible;

        var parts = new List<string>();
        var year = list.ReleaseDate is { Length: >= 4 } d ? d[..4] : _result.Year;
        if (!string.IsNullOrEmpty(year)) parts.Add(year);
        if (list.Tracks.Count > 0)
        {
            parts.Add(list.Tracks.Count == 1 ? "1 song" : $"{list.Tracks.Count} songs");
            var total = list.Tracks.Sum(t => t.Duration ?? 0);
            if (total > 0) parts.Add(FormatLongDuration(total));
        }
        if (list.Followers is > 0) parts.Add($"{list.Followers:N0} followers");
        if (list.Listeners is > 0) parts.Add($"{list.Listeners:N0} monthly listeners");
        MetaText.Text = string.Join(" · ", parts);

        var connected = App.Services.SpotiFlacServer.IsConfigured;
        DownloadAllButton.IsEnabled = connected && list.Tracks.Count > 0;
        SelectAllButton.IsEnabled = list.Tracks.Count > 1;
        _selectedCount = 0;
        UpdateSelectionButtons();

        if (_result.Kind == "artist")
        {
            DiscographyList.Visibility = Visibility.Visible;
            DiscographyList.ItemsSource = BuildGroups(list.Tracks);
        }
        else
        {
            var showAlbum = _result.Kind == "playlist";
            FlatTracksList.Visibility = Visibility.Visible;
            FlatTracksList.ItemsSource = BuildRows(list.Tracks, showAlbum);
        }
    }

    private ObservableCollection<TracklistTrackRow> BuildRows(IReadOnlyList<SpotiFlacTrack> tracks, bool showAlbum)
    {
        var rows = new ObservableCollection<TracklistTrackRow>();
        foreach (var track in tracks)
        {
            var row = new TracklistTrackRow(track, showAlbum);
            row.PropertyChanged += Row_PropertyChanged;
            rows.Add(row);
        }
        return rows;
    }

    private ObservableCollection<AlbumGroupRow> BuildGroups(IReadOnlyList<SpotiFlacTrack> tracks)
    {
        var order = new List<string>();
        var byAlbum = new Dictionary<string, List<SpotiFlacTrack>>();
        foreach (var track in tracks)
        {
            if (!byAlbum.ContainsKey(track.Album)) { order.Add(track.Album); byAlbum[track.Album] = []; }
            byAlbum[track.Album].Add(track);
        }

        var groups = new ObservableCollection<AlbumGroupRow>();
        foreach (var name in order)
        {
            var albumTracks = byAlbum[name];
            var rows = BuildRows(albumTracks, showAlbum: false);
            var year = albumTracks[0].ReleaseDate is { Length: >= 4 } d ? d[..4] : null;
            var caption = string.Join(" · ", new[] { year, albumTracks.Count == 1 ? "1 song" : $"{albumTracks.Count} songs" }.Where(x => !string.IsNullOrEmpty(x)));
            groups.Add(new AlbumGroupRow(string.IsNullOrEmpty(name) ? "Other songs" : name, caption, CoverFrom(albumTracks[0].Cover), rows));
        }
        return groups;
    }

    private void Row_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(TracklistTrackRow.IsSelected) || sender is not TracklistTrackRow row) return;
        _selectedCount += row.IsSelected ? 1 : -1;
        UpdateSelectionButtons();
    }

    private void UpdateSelectionButtons()
    {
        DownloadSelectedButton.IsEnabled = _selectedCount > 0 && App.Services.SpotiFlacServer.IsConfigured;
        DownloadSelectedButton.Content = _selectedCount > 0 ? $"Download {_selectedCount} Selected" : "Download Selected";
        var all = GetAllRows().ToArray();
        SelectAllButton.Content = all.Length > 0 && all.All(r => r.IsSelected) ? "Select None" : "Select All";
    }

    private IEnumerable<TracklistTrackRow> GetAllRows()
    {
        if (FlatTracksList.ItemsSource is IEnumerable<TracklistTrackRow> flat) return flat;
        if (DiscographyList.ItemsSource is IEnumerable<AlbumGroupRow> groups) return groups.SelectMany(g => g.Tracks);
        return [];
    }

    private void DownloadAll_Click(object sender, RoutedEventArgs e) => App.Services.SpotiFlacServer.Enqueue(_result);

    private void DownloadSelected_Click(object sender, RoutedEventArgs e)
    {
        var indices = GetAllRows().Where(r => r.IsSelected).Select(r => r.Index).ToArray();
        if (indices.Length == 0) return;
        App.Services.SpotiFlacServer.Enqueue(_result, indices);
        foreach (var row in GetAllRows()) row.IsSelected = false;
    }

    private void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        var all = GetAllRows().ToArray();
        var makeSelected = !(all.Length > 0 && all.All(r => r.IsSelected));
        foreach (var row in all) row.IsSelected = makeSelected;
    }

    private async void Retry_Click(object sender, RoutedEventArgs e) => await LoadAsync();

    private void Back_Click(object sender, RoutedEventArgs e) => App.MainWindow.GoBackOrHome();

    private void DownloadsOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(RefreshDownloads);

    private void RefreshDownloads()
    {
        var downloads = App.Services.SpotiFlacServer.Downloads;
        DownloadsPanel.Visibility = downloads.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        DownloadsList.ItemsSource = downloads.Select(d => new DownloadRow(d)).ToArray();
    }

    private static BitmapImage? CoverFrom(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) ? new BitmapImage(uri) : null;

    private static string FormatLongDuration(double seconds)
    {
        var minutes = (int)(seconds / 60);
        return minutes >= 60 ? $"{minutes / 60} hr {minutes % 60} min" : $"{minutes} min";
    }

    private static string FormatTrackDuration(double? seconds)
    {
        if (seconds is not { } value || value < 0) return "";
        var span = TimeSpan.FromSeconds(value);
        return $"{(int)span.TotalMinutes}:{span.Seconds:00}";
    }

    private sealed class TracklistTrackRow(SpotiFlacTrack track, bool showAlbum) : INotifyPropertyChanged
    {
        private bool _isSelected;

        public int Index { get; } = track.Index;
        public string Number => (track.Index + 1).ToString();
        public string Title { get; } = track.Title;
        public string Artist { get; } = track.Artist;
        public string Album { get; } = track.Album;
        public string DurationText { get; } = FormatTrackDuration(track.Duration);
        public BitmapImage? CoverImage { get; } = CoverFrom(track.Cover);
        public Visibility ShowAlbum { get; } = showAlbum ? Visibility.Visible : Visibility.Collapsed;
        public Visibility ShowCover { get; } = showAlbum ? Visibility.Visible : Visibility.Collapsed;
        public Visibility ExplicitVisibility { get; } = track.Explicit ? Visibility.Visible : Visibility.Collapsed;
        public Visibility InLibraryVisibility { get; } = LibraryMatch.HasSong(track.Title, track.Artist, App.Services.Library) ? Visibility.Visible : Visibility.Collapsed;

        public bool IsSelected
        {
            get => _isSelected;
            set { if (_isSelected == value) return; _isSelected = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected))); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }

    private sealed record AlbumGroupRow(string Name, string Caption, BitmapImage? CoverImage, ObservableCollection<TracklistTrackRow> Tracks);

    private sealed class DownloadRow(SpotiFlacDownload download)
    {
        public string Title { get; } = download.Item.Title;
        public bool IsActive { get; } = download.IsActive;
        public Visibility ActiveVisibility { get; } = download.IsActive ? Visibility.Visible : Visibility.Collapsed;
        public string StatusText { get; } = download.State switch
        {
            SpotiFlacDownloadState.Waiting => "Waiting…",
            SpotiFlacDownloadState.Preparing => "Preparing…",
            SpotiFlacDownloadState.Downloading => download.Progress ?? "Downloading…",
            SpotiFlacDownloadState.Finished => download.TrackCount == 1 ? "1 track" : $"{download.TrackCount} tracks",
            SpotiFlacDownloadState.Failed => download.Error ?? "Failed",
            _ => "Unknown — check SpotiFLAC"
        };
    }
}
