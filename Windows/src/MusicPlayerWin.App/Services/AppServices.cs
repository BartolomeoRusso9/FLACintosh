using MusicPlayerWin.Core;
using MusicPlayerWin.Core.Audio;
using MusicPlayerWin.Core.History;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Lyrics;
using MusicPlayerWin.Core.Offline;
using MusicPlayerWin.Core.Playback;
using MusicPlayerWin.Core.Playlists;
using MusicPlayerWin.Core.Servers;

namespace MusicPlayerWin.App.Services;

/// <summary>Application-wide orchestration shared by all WinUI pages.</summary>
public sealed class AppServices : IAsyncDisposable
{
    private readonly WindowsDualDeckAudioEngine _engine;
    private readonly LyricsFetcher _lyricsFetcher = new();
    private readonly SettingsStore _settings = new();
    private readonly MusicServerStore _servers = new();
    private readonly ListeningHistoryStore _history = new();
    private readonly DiscordRichPresenceService _discord = new();
    private readonly ScrobblingService _scrobbling;
    private readonly SpotiFlacServerClient _spotiFlacServer = new();
    private readonly SpotiFlacCliBridge _spotiFlacCli = new();
    private readonly CastV2Client _cast = new();
    private readonly CastDiscoveryService _castDiscovery = new();
    private readonly LocalMediaServer _localMediaServer = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _libraryGate = new(1, 1);
    private readonly PlaybackController _playback;
    private readonly List<ServerPlaylist> _serverPlaylists = [];
    private LibraryWatcher? _libraryWatcher;
    private CancellationTokenSource? _scanCancellation;
    private bool _disposed;

    public AppServices()
    {
        Library = new LibraryStore();
        Playlists = new PlaylistStore();
        _scrobbling = new ScrobblingService(_history);
        if (!string.IsNullOrWhiteSpace(_settings.Current.Integrations.LastFmSharedSecret) && WindowsCredentialStore.Read("MusicPlayerWin/LastFmSecret") is null)
        {
            _scrobbling.SaveLastFmSecret(_settings.Current.Integrations.LastFmSharedSecret);
            _settings.Update(x => x with { Integrations = x.Integrations with { LastFmSharedSecret = "" } });
        }
        Offline = new OfflineStore();
        _engine = new WindowsDualDeckAudioEngine();
        _engine.ApplyEffects(_settings.Current.Effects);

        if (_settings.Current.LibraryRoot is { Length: > 0 } root && Directory.Exists(root))
        {
            Library.SetRoot(root);
            ConfigureLibraryWatcher(root);
        }

        _playback = new PlaybackController(_engine, sourceResolver: ResolvePlaybackUriAsync, history: _history, trackGainResolver: ResolveReplayGain)
        {
            MoreToPlay = () => Library.InOrder()
        };
        _playback.Queue.AutoPlay = _settings.Current.AutoPlay;
        _engine.ConfigureTransition(_settings.Current.Effects.Gapless, _settings.Current.Effects.Crossfade, _settings.Current.Effects.CrossfadeSeconds);
        _engine.RemoteCommand += EngineOnRemoteCommand;
        _playback.TrackChanged += PlaybackOnTrackChanged;
        _playback.StateChanged += PlaybackOnStateChanged;
        _playback.Error += PlaybackOnError;
        _engine.StateChanged += EngineOnStateChanged;
        ConfigureIntegrations();
        _spotiFlacCli.Detect();
        _spotiFlacServer.DownloadFinished += SpotiFlacServerOnDownloadFinished;
        AppLog.Info("MusicPlayerWin services initialized.");
    }

    public LibraryStore Library { get; }
    public PlaylistStore Playlists { get; }
    public OfflineStore Offline { get; }
    public MusicServerStore Servers => _servers;
    public AppSettings Settings => _settings.Current;
    public AudioEffectsSettings Effects => _settings.Current.Effects;
    public PlaybackController Playback => _playback;
    public ListeningSummary ListeningSummary => _history.Summary();
    public ListeningSummary SummaryFor(RecapPeriod period) => _history.SummaryForPeriod(period);
    public int[] HoursOfDay(RecapPeriod period) => _history.HoursOfDay(period);
    public (DateOnly Date, double Minutes)? BusiestDay(RecapPeriod period) => _history.BusiestDay(period);
    public int LongestStreakDays(RecapPeriod period) => _history.LongestStreakDays(period);
    public DiscordRichPresenceService Discord => _discord;
    public ScrobblingService Scrobbling => _scrobbling;
    public SpotiFlacServerClient SpotiFlacServer => _spotiFlacServer;
    public SpotiFlacCliBridge SpotiFlacCli => _spotiFlacCli;
    public CastV2Client Cast => _cast;
    public CastDiscoveryService CastDiscovery => _castDiscovery;
    public IReadOnlyList<ListenRecord> RecentListening => _history.Recent(50);
    public IReadOnlyList<ListeningDay> ListeningDays => _history.Daily(DateTimeOffset.UtcNow.AddDays(-29));
    public IReadOnlyList<ServerPlaylist> ServerPlaylists => _serverPlaylists.ToArray();
    public IReadOnlyList<LibrarySource> Sources => new[] { LibrarySource.Folder }.Concat(_servers.Servers.Select(s => LibrarySource.Server(s.Id))).ToArray();
    public IReadOnlyDictionary<string, OfflineProgress> ActiveOfflineDownloads => Offline.Progress;
    public bool IsScanning { get; private set; }
    public int ScanCompleted { get; private set; }
    public int ScanTotal { get; private set; }
    public string? ScanError { get; private set; }

    public event EventHandler? LibraryChanged;
    public event EventHandler? PlayerStateChanged;
    public event EventHandler? SettingsChanged;
    public event EventHandler? PlaylistsChanged;
    public event EventHandler<string>? ErrorRaised;

    public void NotifyPlaylistsChanged() => PlaylistsChanged?.Invoke(this, EventArgs.Empty);
    public void NotifyLibraryChanged() => LibraryChanged?.Invoke(this, EventArgs.Empty);
    public void SetSourceHidden(LibrarySource source, bool hidden)
    {
        Library.SetHidden(source, hidden);
        NotifyLibraryChanged();
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ConfigureIntegrations()
    {
        var integrations = _settings.Current.Integrations;
        _scrobbling.Configure(integrations.LastFmEnabled, integrations.LastFmApiKey, integrations.LastFmSharedSecret, integrations.ListenBrainzEnabled, integrations.ListenBrainzServer);
        var spotToken = WindowsCredentialStore.Read("MusicPlayerWin/SpotiFlac") ?? "";
        if (!string.IsNullOrWhiteSpace(integrations.SpotiFlacAddress) && !string.IsNullOrWhiteSpace(spotToken))
            _ = _spotiFlacServer.ConfigureAsync(integrations.SpotiFlacAddress, spotToken).ContinueWith(t =>
            {
                if (t.Exception is not null) AppLog.Warn("SpotiFLAC reconnect failed.", t.Exception.GetBaseException());
            }, TaskScheduler.Default);
        _ = _discord.ConfigureAsync(integrations.DiscordEnabled, integrations.DiscordApplicationId, integrations.DiscordArtwork, _playback.CurrentTrack, false);
    }

    private void ConfigureLibraryWatcher(string root)
    {
        _libraryWatcher?.Dispose();
        if (!Directory.Exists(root)) return;
        _libraryWatcher = new LibraryWatcher(root);
        _libraryWatcher.Changed += LibraryWatcherOnChanged;
    }

    private void LibraryWatcherOnChanged(object? sender, IReadOnlyList<string> paths)
    {
        if (_disposed || paths.Count == 0) return;
        _ = ApplyLibraryChangesAsync(paths);
    }

    private async Task ApplyLibraryChangesAsync(IReadOnlyList<string> paths)
    {
        if (!await _libraryGate.WaitAsync(0).ConfigureAwait(false)) return;
        try
        {
            var unique = paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            var requiresFull = unique.Length > 64 || unique.Any(IsLibrarySidecarChange);
            if (requiresFull)
            {
                var root = Library.RootPath;
                if (!string.IsNullOrWhiteSpace(root))
                    await ScanFolderCoreAsync(root, persistRoot: false, CancellationToken.None).ConfigureAwait(false);
                return;
            }

            foreach (var path in unique)
            {
                if (LibraryScanner.IsSupportedAudioFile(path) && File.Exists(path))
                {
                    var batch = await LibraryScanner.ScanFileAsync(new Uri(Path.GetFullPath(path))).ConfigureAwait(false);
                    if (batch is not null) Library.AddBatch(batch.Tracks, batch.Covers);
                }
                else if (LibraryScanner.IsSupportedAudioFile(path) && !File.Exists(path))
                {
                    Library.Remove(new Uri(Path.GetFullPath(path)));
                }
            }
            Library.RemoveMissingUnderRoot();
            LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            AppLog.Warn("Incremental library refresh failed; keeping current index.", ex);
            ErrorRaised?.Invoke(this, ex.Message);
        }
        finally { _libraryGate.Release(); }
    }

    private static bool IsLibrarySidecarChange(string path)
    {
        var ext = Path.GetExtension(path);
        return ext.Equals(".lrc", StringComparison.OrdinalIgnoreCase) || ext.Equals(".jpg", StringComparison.OrdinalIgnoreCase) || ext.Equals(".jpeg", StringComparison.OrdinalIgnoreCase) || ext.Equals(".png", StringComparison.OrdinalIgnoreCase);
    }

    public async Task ScanFolderAsync(string folder, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(folder)) return;
        await _libraryGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await ScanFolderCoreAsync(folder, persistRoot: true, cancellationToken).ConfigureAwait(false); }
        finally { _libraryGate.Release(); }
    }

    private async Task ScanFolderCoreAsync(string folder, bool persistRoot, CancellationToken cancellationToken)
    {
        _scanCancellation?.Cancel();
        _scanCancellation?.Dispose();
        _scanCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
        var ct = _scanCancellation.Token;
        _libraryWatcher?.Dispose();
        _libraryWatcher = null;
        var fullRoot = Path.GetFullPath(folder);
        Library.SetRoot(fullRoot);
        if (persistRoot)
        {
            _settings.Update(x => x with { LibraryRoot = fullRoot });
            SettingsChanged?.Invoke(this, EventArgs.Empty);
        }
        IsScanning = true; ScanCompleted = 0; ScanTotal = 0; ScanError = null;
        Library.Clear(); LibraryChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            var files = await LibraryScanner.AudioFilesAsync(fullRoot, ct).ConfigureAwait(false);
            ScanTotal = files.Count;
            LibraryChanged?.Invoke(this, EventArgs.Empty);
            await foreach (var batch in LibraryScanner.ReadAsync(files, cancellationToken: ct).ConfigureAwait(false))
            {
                Library.AddBatch(batch.Tracks, batch.Covers);
                ScanCompleted = Math.Min(files.Count, ScanCompleted + batch.Tracks.Count);
                LibraryChanged?.Invoke(this, EventArgs.Empty);
            }
            await LoadServersIntoLibraryAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception ex)
        {
            ScanError = ex.Message;
            AppLog.Error("Library scan failed.", ex);
            ErrorRaised?.Invoke(this, ex.Message);
        }
        finally
        {
            IsScanning = false;
            ConfigureLibraryWatcher(fullRoot);
            LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task ReloadAllSourcesAsync(CancellationToken cancellationToken = default)
    {
        var root = Library.RootPath;
        if (!string.IsNullOrWhiteSpace(root) && Directory.Exists(root)) await ScanFolderAsync(root, cancellationToken).ConfigureAwait(false);
        else await LoadServersIntoLibraryAsync(cancellationToken).ConfigureAwait(false);
    }

    public IReadOnlyList<LibraryTrack> SearchTracks(string query, int limit = 100) => Library.SearchTracks(query, limit);
    public IReadOnlyList<LibraryAlbum> SearchAlbums(string query, int limit = 100) => Library.SearchAlbums(query, limit);
    public IReadOnlyList<LibraryArtist> SearchArtists(string query, int limit = 100) => Library.SearchArtists(query, limit);

    public void UpdateIntegrationSettings(Func<IntegrationSettings, IntegrationSettings> change)
    {
        _settings.Update(x => x with { Integrations = change(x.Integrations) });
        ConfigureIntegrations();
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetAutoPlay(bool enabled)
    {
        _playback.Queue.AutoPlay = enabled;
        _settings.Update(x => x with { AutoPlay = enabled });
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetStartWithWindows(bool enabled)
    {
        WindowsStartupService.SetEnabled(enabled);
        _settings.Update(x => x with { StartWithWindows = enabled });
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetMinimizeToTray(bool enabled)
    {
        _settings.Update(x => x with { MinimizeToTray = enabled });
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetAudioEffects(AudioEffectsSettings effects)
    {
        effects = effects.Normalize();
        _settings.Update(x => x with { Effects = effects });
        _engine.ApplyEffects(effects);
        _engine.ConfigureTransition(effects.Gapless, effects.Crossfade, effects.CrossfadeSeconds);
        _ = _playback.ReapplyCurrentGainAsync();
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetEqualizerGain(int band, double gain)
    {
        if (band is < 0 or >= 10) return;
        var gains = (double[])Effects.Gains.Clone(); gains[band] = Math.Clamp(gain, -12, 12);
        SetAudioEffects((Effects with { Gains = gains, PresetName = "Custom" }).Normalize());
    }

    public void ApplyEqualizerPreset(string preset)
    {
        if (!AudioEffectsSettings.Presets.TryGetValue(preset, out var gains)) return;
        SetAudioEffects(Effects with { Gains = (double[])gains.Clone(), PresetName = preset });
    }

    public async Task AddServerAsync(MusicServer server, string password, CancellationToken cancellationToken = default)
    {
        WindowsCredentialStore.Save(server.PasswordKey, server.Username, password);
        _servers.Add(server);
        await LoadServerIntoLibraryAsync(server, cancellationToken).ConfigureAwait(false);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty); LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task UpdateServerAsync(MusicServer server, string? password = null, CancellationToken cancellationToken = default)
    {
        if (!string.IsNullOrWhiteSpace(password)) WindowsCredentialStore.Save(server.PasswordKey, server.Username, password);
        _servers.Update(server);
        await LoadServerIntoLibraryAsync(server, cancellationToken).ConfigureAwait(false);
        SettingsChanged?.Invoke(this, EventArgs.Empty);
        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    public void UpdateServer(MusicServer server) { _servers.Update(server); _ = ReloadAllSourcesAsync(); SettingsChanged?.Invoke(this, EventArgs.Empty); }

    public void RemoveServer(Guid id)
    {
        var server = _servers.Find(id);
        if (server is not null) WindowsCredentialStore.Remove(server.PasswordKey);
        _servers.Remove(id); _serverPlaylists.RemoveAll(x => x.ServerId == id);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty); _ = ReloadAllSourcesAsync();
    }

    public async Task<bool> TestServerAsync(MusicServer server, string password, CancellationToken cancellationToken = default)
    {
        try { await MusicServerFactory.Create(server, password).PingAsync(cancellationToken).ConfigureAwait(false); return true; }
        catch (Exception ex) { AppLog.Warn($"Server test failed for {server.Name}.", ex); return false; }
    }

    private double ResolveReplayGain(LibraryTrack track, Uri source)
    {
        if (source is null || !source.IsFile || Effects.ReplayGain == AudioEffectsSettings.ReplayGainMode.Off) return 0;
        return ReplayGainReader.Read(source)?.GainFor(Effects.ReplayGain, Effects.ReplayGainPreamp) ?? 0;
    }

    public async Task FindLyricsAsync(IEnumerable<LibraryTrack> tracks, CancellationToken cancellationToken = default)
    {
        foreach (var track in tracks.Where(x => !x.HasLyrics && x.Url.IsFile))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var lrc = await _lyricsFetcher.FetchAsync(track.Title, track.Artist, track.Duration ?? 0, cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(lrc)) continue;
            MusicPlayerWin.Core.Infrastructure.AtomicFile.WriteAllText(Path.ChangeExtension(track.Url.LocalPath, ".lrc"), lrc);
        }
        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ConfigureDiscord(bool enabled, string applicationId, bool artwork)
    {
        _settings.Update(x => x with { Integrations = x.Integrations with { DiscordEnabled = enabled, DiscordApplicationId = applicationId.Trim(), DiscordArtwork = artwork } });
        _ = _discord.ConfigureAsync(enabled, applicationId, artwork, Playback.CurrentTrack, Playback.Audio.State.IsPlaying);
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ConfigureLastFm(bool enabled, string apiKey, string sharedSecret, string sessionKey)
    {
        var existingSecret = WindowsCredentialStore.Read("MusicPlayerWin/LastFmSecret");
        if (!string.IsNullOrWhiteSpace(sharedSecret)) _scrobbling.SaveLastFmSecret(sharedSecret);
        else if (string.IsNullOrWhiteSpace(existingSecret)) _scrobbling.RemoveLastFmSecret();
        _settings.Update(x => x with { Integrations = x.Integrations with { LastFmEnabled = enabled, LastFmApiKey = apiKey.Trim(), LastFmSharedSecret = "" } });
        if (!string.IsNullOrWhiteSpace(sessionKey)) _scrobbling.SaveLastFmSession(sessionKey);
        ReconfigureScrobbling();
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task<Uri?> BeginLastFmAuthorizationAsync(CancellationToken cancellationToken = default) => await _scrobbling.BeginLastFmAuthorizationAsync(cancellationToken).ConfigureAwait(false);
    public async Task<bool> CompleteLastFmAuthorizationAsync(CancellationToken cancellationToken = default) => await _scrobbling.CompleteLastFmAuthorizationAsync(cancellationToken).ConfigureAwait(false);

    public void ConfigureListenBrainz(bool enabled, string server, string token)
    {
        _settings.Update(x => x with { Integrations = x.Integrations with { ListenBrainzEnabled = enabled, ListenBrainzServer = string.IsNullOrWhiteSpace(server) ? "https://api.listenbrainz.org" : server.TrimEnd('/') } });
        if (!string.IsNullOrWhiteSpace(token)) _scrobbling.SaveListenBrainzToken(token);
        ReconfigureScrobbling(); SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ReconfigureScrobbling()
    {
        var i = Settings.Integrations;
        _scrobbling.Configure(i.LastFmEnabled, i.LastFmApiKey, i.LastFmSharedSecret, i.ListenBrainzEnabled, i.ListenBrainzServer);
    }

    public async Task ConfigureSpotiFlacAsync(string address, string token, CancellationToken cancellationToken = default)
    {
        await _spotiFlacServer.ConfigureAsync(address, token, cancellationToken).ConfigureAwait(false);
        _settings.Update(x => x with { Integrations = x.Integrations with { SpotiFlacAddress = address.TrimEnd('/') } });
        WindowsCredentialStore.Save("MusicPlayerWin/SpotiFlac", "token", token.Trim()); SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task PlayFileAsync(string path, CancellationToken cancellationToken = default)
    {
        var full = Path.GetFullPath(path);
        if (!File.Exists(full)) return;
        var track = Library.Find(new Uri(full));
        if (track is null)
        {
            var batch = await LibraryScanner.ScanFileAsync(new Uri(full), cancellationToken).ConfigureAwait(false);
            track = batch?.Tracks.FirstOrDefault();
            if (track is null) track = new LibraryTrack { Id = new Uri(full), Title = Path.GetFileNameWithoutExtension(full), Artist = "Unknown Artist", AlbumArtist = "Unknown Artist", Album = "Unknown Album", HasLyrics = File.Exists(Path.ChangeExtension(full, ".lrc")) };
            Library.Add(track); LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
        await _playback.PlayAsync([track], 0, cancellationToken).ConfigureAwait(false);
    }

    public async Task CastCurrentAsync(string receiverHost, CancellationToken cancellationToken = default)
    {
        var track = Playback.CurrentTrack ?? throw new InvalidOperationException("Nothing is playing.");
        if (string.IsNullOrWhiteSpace(receiverHost)) throw new ArgumentException("A receiver address is required.", nameof(receiverHost));
        await _cast.ConnectAsync(receiverHost, 8009, cancellationToken).ConfigureAwait(false);
        var source = await ResolvePlaybackUriAsync(track, cancellationToken).ConfigureAwait(false);
        var url = source.IsFile ? await _localMediaServer.PublishAsync(source.LocalPath, receiverHost, cancellationToken).ConfigureAwait(false) : source;
        await _cast.LoadUrlAsync(url.ToString(), GetCastContentType(source), cancellationToken).ConfigureAwait(false);
    }

    private static string GetCastContentType(Uri source) => source.IsFile ? Path.GetExtension(source.LocalPath).ToLowerInvariant() switch
    {
        ".mp3" => "audio/mpeg", ".m4a" or ".m4b" or ".aac" => "audio/mp4", ".wav" => "audio/wav", ".aif" or ".aiff" => "audio/aiff", ".ogg" or ".oga" => "audio/ogg", ".opus" => "audio/ogg", ".flac" => "audio/flac", _ => "application/octet-stream"
    } : "audio/flac";

    private async void SpotiFlacServerOnDownloadFinished(object? sender, EventArgs e)
    {
        try { await ReloadAllSourcesAsync().ConfigureAwait(false); }
        catch (Exception ex) { AppLog.Warn("Library refresh after a SpotiFLAC download failed.", ex); }
    }

    public Task ClearHistoryAsync() { _history.Clear(); PlayerStateChanged?.Invoke(this, EventArgs.Empty); return Task.CompletedTask; }
    public Task PlayAlbumAsync(LibraryAlbum album) => album.Tracks.Count == 0 ? Task.CompletedTask : _playback.PlayAsync(album.Tracks, 0);
    public Task PlayAllAsync() { var tracks = Library.InOrder(); return tracks.Count == 0 ? Task.CompletedTask : _playback.PlayAsync(tracks, 0); }
    public Task PlayPlaylistAsync(Playlist playlist) { var resolved = Playlists.Resolve(playlist, Library, Offline).Where(x => x is not null).Cast<LibraryTrack>().ToArray(); return resolved.Length == 0 ? Task.CompletedTask : _playback.PlayAsync(resolved, 0); }
    public Task PlayServerPlaylistAsync(ServerPlaylist playlist) { var resolved = playlist.TrackUrls.Select(url => Library.FindEquivalent(url, playlist.ServerId)).Where(x => x is not null).Cast<LibraryTrack>().ToArray(); return resolved.Length == 0 ? Task.CompletedTask : _playback.PlayAsync(resolved, 0); }

    public Playlist SaveQueueAsPlaylist(string? name = null) => Playlists.CreateFromQueue(name, Playback.Queue.Queue);

    public void UpdateAppTheme(string theme)
    {
        var normalized = theme is "Light" or "Dark" ? theme : "System";
        _settings.Update(x => x with { Theme = normalized });
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    private async void PlaybackOnTrackChanged(object? sender, EventArgs e)
    {
        try
        {
            var track = _playback.CurrentTrack;
            _engine.UpdateNowPlaying(track?.Title, track?.Artist, track?.Album);
            var cover = track is null ? null : Library.Albums.FirstOrDefault(a => a.Tracks.Any(t => t.Key == track.Key))?.Cover;
            await _engine.UpdateNowPlayingArtworkAsync(cover).ConfigureAwait(false);
            await _discord.UpdateAsync(track, Playback.Audio.State.IsPlaying, Settings.Integrations.DiscordArtwork).ConfigureAwait(false);
            await _scrobbling.UpdateNowPlayingAsync(track, Playback.Audio.State.IsPlaying).ConfigureAwait(false);
        }
        catch (Exception ex) { AppLog.Warn("Track integration update failed.", ex); }
        PlayerStateChanged?.Invoke(this, EventArgs.Empty);
    }

    private async void PlaybackOnError(object? sender, AudioErrorEventArgs e)
    {
        AppLog.Error("Audio error.", e.Exception);
        ErrorRaised?.Invoke(this, e.Exception.Message);
        await Task.CompletedTask;
    }

    private void PlaybackOnStateChanged(object? sender, EventArgs e) => PlayerStateChanged?.Invoke(this, EventArgs.Empty);
    private void EngineOnStateChanged(object? sender, EventArgs e) => PlayerStateChanged?.Invoke(this, EventArgs.Empty);

    private async void EngineOnRemoteCommand(object? sender, MediaRemoteCommandEventArgs args)
    {
        try
        {
            switch (args.Command)
            {
                case MediaRemoteCommand.Play: if (!Playback.Audio.State.IsPlaying) Playback.Audio.Play(); break;
                case MediaRemoteCommand.Pause: if (Playback.Audio.State.IsPlaying) Playback.Audio.Pause(); break;
                case MediaRemoteCommand.Next: await Playback.NextAsync().ConfigureAwait(false); break;
                case MediaRemoteCommand.Previous: await Playback.PreviousAsync().ConfigureAwait(false); break;
                case MediaRemoteCommand.Stop: Playback.Stop(); break;
            }
        }
        catch (Exception ex) { AppLog.Error("Media command failed.", ex); }
    }

    private async Task LoadServersIntoLibraryAsync(CancellationToken ct)
    {
        _serverPlaylists.Clear(); PlaylistsChanged?.Invoke(this, EventArgs.Empty);
        foreach (var server in _servers.Servers) await LoadServerIntoLibraryAsync(server, ct).ConfigureAwait(false);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task LoadServerIntoLibraryAsync(MusicServer server, CancellationToken ct)
    {
        var password = WindowsCredentialStore.Read(server.PasswordKey); if (password is null) return;
        try
        {
            var client = MusicServerFactory.Create(server, password);
            var albums = await client.AlbumsAsync(cancellationToken: ct).ConfigureAwait(false);
            Library.AddAlbums(albums);
            var playlists = await client.PlaylistsAsync(ct).ConfigureAwait(false);
            _serverPlaylists.RemoveAll(x => x.ServerId == server.Id); _serverPlaylists.AddRange(playlists.Select(p => p with { ServerName = server.Name }));
            PlaylistsChanged?.Invoke(this, EventArgs.Empty); LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex) { ScanError = $"{server.Name}: {ex.Message}"; AppLog.Warn($"Could not load {server.Name}.", ex); }
    }

    private async Task<Uri> ResolvePlaybackUriAsync(LibraryTrack track, CancellationToken cancellationToken)
    {
        if (track.Url.IsFile) return track.Url;
        if (Offline.LocalFile(track.Url) is { } offline) return offline;
        return await RemoteCache.FileAsync(track.Url, cancellationToken).ConfigureAwait(false);
    }

    public IReadOnlyList<ServiceHealth> GetHealth()
    {
        return [
            new("Library", Library.RootPath is not null || Library.Count > 0, Library.RootPath ?? "No local library"),
            new("Audio", !(_engine.Format is null && Playback.CurrentTrack is not null), Playback.CurrentTrack is null ? "Idle" : $"{_engine.Format?.SampleRate ?? 0} Hz"),
            new("Discord", !Settings.Integrations.DiscordEnabled || Discord.Connected, Discord.Status),
            new("SpotiFLAC", string.IsNullOrWhiteSpace(Settings.Integrations.SpotiFlacAddress) || SpotiFlacServer.IsConfigured, SpotiFlacServer.IsConfigured ? "Configured" : "Not configured"),
            new("Last.fm", !Settings.Integrations.LastFmEnabled || Scrobbling.HasLastFmSession, Scrobbling.HasLastFmSession ? "Authorized" : "Needs authorization"),
            new("ListenBrainz", !Settings.Integrations.ListenBrainzEnabled || Scrobbling.HasListenBrainzToken, Scrobbling.HasListenBrainzToken ? "Token configured" : "Needs token"),
            new("Google Cast", !Cast.Connected || !string.IsNullOrWhiteSpace(Cast.ReceiverHost), Cast.Connected ? $"Connected to {Cast.ReceiverHost}" : "Disconnected"),
            new("File associations", !Settings.Integrations.FileAssociationsRegistered || FileAssociationService.IsRegistered(), FileAssociationService.IsRegistered() ? "Registered" : "Not registered")
        ];
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _lifetime.Cancel(); _scanCancellation?.Cancel(); _scanCancellation?.Dispose();
        _libraryWatcher?.Dispose(); _libraryWatcher = null;
        _engine.RemoteCommand -= EngineOnRemoteCommand;
        _playback.TrackChanged -= PlaybackOnTrackChanged;
        _playback.StateChanged -= PlaybackOnStateChanged;
        _playback.Error -= PlaybackOnError;
        _engine.StateChanged -= EngineOnStateChanged;
        try { _history.Finish(); } catch { }
        try { await _scrobbling.FlushAsync().ConfigureAwait(false); } catch (Exception ex) { AppLog.Warn("Final scrobble flush failed.", ex); }
        _spotiFlacServer.DownloadFinished -= SpotiFlacServerOnDownloadFinished;
        await _discord.DisposeAsync().ConfigureAwait(false);
        await _scrobbling.DisposeAsync().ConfigureAwait(false);
        await _spotiFlacServer.DisposeAsync().ConfigureAwait(false);
        _spotiFlacCli.Dispose();
        await _cast.DisposeAsync().ConfigureAwait(false);
        await _localMediaServer.DisposeAsync().ConfigureAwait(false);
        await _playback.DisposeAsync().ConfigureAwait(false);
        _libraryGate.Dispose(); _lifetime.Dispose();
        AppLog.Info("MusicPlayerWin services disposed.");
    }
}
