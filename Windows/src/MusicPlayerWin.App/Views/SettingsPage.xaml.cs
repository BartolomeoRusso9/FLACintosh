using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using MusicPlayerWin.Core;
using MusicPlayerWin.Core.Audio;
using MusicPlayerWin.Core.Library;
using MusicPlayerWin.Core.Offline;
using MusicPlayerWin.Core.Servers;
using MusicPlayerWin.App.Services;
using Windows.Storage.Pickers;
using WinRT.Interop;
using System.Diagnostics;
using Windows.System;

namespace MusicPlayerWin.App.Views;

public sealed partial class SettingsPage : Page
{
    private bool _refreshing;
    private readonly Slider[] _eqSliders;
    private sealed record SourceRow(string Key, string Name, string Detail, bool IsVisible);

    public SettingsPage()
    {
        InitializeComponent();
        _eqSliders = [Eq0, Eq1, Eq2, Eq3, Eq4, Eq5, Eq6, Eq7, Eq8, Eq9];
        PresetCombo.ItemsSource = AudioEffectsSettings.Presets.Keys.ToArray();
        ThemeCombo.SelectedIndex = App.Services.Settings.Theme switch { "Dark" => 1, "Light" => 2, _ => 0 };
        StartupToggle.IsOn = App.Services.Settings.StartWithWindows || WindowsStartupService.IsEnabled();
        TrayToggle.IsOn = App.Services.Settings.MinimizeToTray;
        Loaded += (_, _) => Refresh();
        App.Services.LibraryChanged += ServicesOnChanged;
        App.Services.SettingsChanged += ServicesOnChanged;
        Unloaded += (_, _) =>
        {
            App.Services.LibraryChanged -= ServicesOnChanged;
            App.Services.SettingsChanged -= ServicesOnChanged;
        };
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        _refreshing = true;
        var library = App.Services.Library;
        LibraryPath.Text = library.RootPath is { Length: > 0 } path ? path : "No library folder selected";
        Stats.Text = $"{library.Tracks.Count} songs · {library.Albums.Count} albums · {library.Artists.Count} artists";
        AutoPlayToggle.IsOn = App.Services.Playback.Queue.AutoPlay;
        var effects = App.Services.Effects.Normalize();
        EqualizerToggle.IsOn = effects.EqualizerEnabled;
        GaplessToggle.IsOn = effects.Gapless;
        CrossfadeToggle.IsOn = effects.Crossfade;
        CrossfadeSlider.Value = effects.CrossfadeSeconds;
        CrossfadeValue.Text = $"{effects.CrossfadeSeconds:0.#} s";
        ReplayGainCombo.SelectedIndex = effects.ReplayGain switch
        {
            AudioEffectsSettings.ReplayGainMode.Track => 1,
            AudioEffectsSettings.ReplayGainMode.Album => 2,
            _ => 0
        };
        ReplayGainPreampSlider.Value = effects.ReplayGainPreamp;
        ReplayGainPreampValue.Text = $"Preamp: {effects.ReplayGainPreamp:+0.0;-0.0;0.0} dB";
        for (var i = 0; i < _eqSliders.Length; i++)
            _eqSliders[i].Value = i < effects.Gains.Length ? effects.Gains[i] : 0;
        PresetCombo.SelectedItem = AudioEffectsSettings.Presets.ContainsKey(effects.PresetName) ? effects.PresetName : null;
        EqHeadroom.Text = effects.EqualizerEnabled && effects.EqualizerHeadroomDb < 0
            ? $"Automatic headroom: {effects.EqualizerHeadroomDb:0.0} dB"
            : "Headroom: 0 dB";
        ServersList.ItemsSource = App.Services.Servers.Servers;
        NoServers.Visibility = App.Services.Servers.Servers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SourcesList.ItemsSource = App.Services.Library.Sources.Select(source => new SourceRow(source.Key, source.IsFolder ? "Local Music" : App.Services.Servers.Find(source.ServerId!.Value)?.Name ?? "Server", source.IsFolder ? (App.Services.Library.RootPath ?? "Local folder") : source.ServerId!.Value.ToString(), !App.Services.Library.IsHidden(source))).ToArray();
        CacheSummary.Text = $"Remote cache: {FormatBytes(RemoteCache.Size())} · Offline: {FormatBytes(App.Services.Offline.SizeBytes)}";
        var integrations = App.Services.Settings.Integrations;
        DiscordToggle.IsOn = integrations.DiscordEnabled;
        DiscordApplicationId.Text = integrations.DiscordApplicationId;
        DiscordArtworkToggle.IsOn = integrations.DiscordArtwork;
        DiscordStatus.Text = App.Services.Discord.Status;
        LastFmStatus.Text = App.Services.Scrobbling.HasLastFmSession ? "Authorized session is stored in Windows Credential Manager." : "Not authorized.";
        LastFmSecret.PlaceholderText = "Stored securely in Windows Credential Manager";
        HealthList.ItemsSource = App.Services.GetHealth();
        LastFmToggle.IsOn = integrations.LastFmEnabled;
        LastFmApiKey.Text = integrations.LastFmApiKey;
        ListenBrainzToggle.IsOn = integrations.ListenBrainzEnabled;
        ListenBrainzServer.Text = integrations.ListenBrainzServer;
        _refreshing = false;
    }


    private void ThemeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refreshing || ThemeCombo.SelectedItem is not ComboBoxItem item || item.Content is not string theme) return;
        App.Services.UpdateAppTheme(theme);
    }

    private async void LastFmAuthorize_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            App.Services.ConfigureLastFm(LastFmToggle.IsOn, LastFmApiKey.Text, LastFmSecret.Password, LastFmSession.Password);
            var uri = await App.Services.BeginLastFmAuthorizationAsync();
            LastFmStatus.Text = uri is null ? "Enter an API key and shared secret first." : "Browser authorization started. Approve the app, then click Complete authorization.";
            if (uri is not null) await Launcher.LaunchUriAsync(uri);
        }
        catch (Exception ex) { LastFmStatus.Text = ex.Message; }
    }

    private async void LastFmComplete_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var ok = await App.Services.CompleteLastFmAuthorizationAsync();
            LastFmStatus.Text = ok ? "Last.fm authorization completed." : "Authorization could not be completed. Approve the browser request first.";
            Refresh();
        }
        catch (Exception ex) { LastFmStatus.Text = ex.Message; }
    }

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"\"{Path.GetDirectoryName(AppLog.LogPath)}\"", UseShellExecute = true }); } catch { }
    }

    private void Equalizer_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetAudioEffects(App.Services.Effects with { EqualizerEnabled = EqualizerToggle.IsOn });
    }

    private void Gapless_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetAudioEffects(App.Services.Effects with { Gapless = GaplessToggle.IsOn });
    }


    private void Crossfade_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetAudioEffects(App.Services.Effects with { Crossfade = CrossfadeToggle.IsOn });
    }

    private void CrossfadeSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_refreshing) return;
        CrossfadeValue.Text = $"{e.NewValue:0.#} s";
        App.Services.SetAudioEffects(App.Services.Effects with { CrossfadeSeconds = e.NewValue });
    }

    private void ReplayGainCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refreshing) return;
        var mode = ReplayGainCombo.SelectedIndex switch
        {
            1 => AudioEffectsSettings.ReplayGainMode.Track,
            2 => AudioEffectsSettings.ReplayGainMode.Album,
            _ => AudioEffectsSettings.ReplayGainMode.Off
        };
        App.Services.SetAudioEffects(App.Services.Effects with { ReplayGain = mode });
    }

    private void ReplayGainPreamp_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_refreshing) return;
        ReplayGainPreampValue.Text = $"Preamp: {e.NewValue:+0.0;-0.0;0.0} dB";
        App.Services.SetAudioEffects(App.Services.Effects with { ReplayGainPreamp = e.NewValue });
    }

    private void EqBand_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_refreshing || sender is not Slider slider || slider.Tag is not string tag || !int.TryParse(tag, out var band)) return;
        App.Services.SetEqualizerGain(band, e.NewValue);
    }

    private void PresetCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refreshing || PresetCombo.SelectedItem is not string preset) return;
        App.Services.ApplyEqualizerPreset(preset);
    }

    private async void Rescan_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null) await App.Services.ScanFolderAsync(folder.Path);
    }

    private async void RefreshSources_Click(object sender, RoutedEventArgs e) => await App.Services.ReloadAllSourcesAsync();

    private void AutoPlay_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetAutoPlay(AutoPlayToggle.IsOn);
    }

    private void Startup_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetStartWithWindows(StartupToggle.IsOn);
    }

    private void Tray_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetMinimizeToTray(TrayToggle.IsOn);
    }

    private async void AddServer_Click(object sender, RoutedEventArgs e)
    {
        var kind = new ComboBox { ItemsSource = new[] { "Jellyfin", "Navidrome / Subsonic" }, SelectedIndex = 0 };
        var name = new TextBox { PlaceholderText = "Name", Header = "Name" };
        var address = new TextBox { PlaceholderText = "http://server:8096", Header = "Address" };
        var username = new TextBox { PlaceholderText = "Username", Header = "Username" };
        var password = new PasswordBox { PlaceholderText = "Password", Header = "Password" };
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(kind); stack.Children.Add(name); stack.Children.Add(address); stack.Children.Add(username); stack.Children.Add(password);

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Add music server",
            Content = stack,
            PrimaryButtonText = "Add",
            CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (!Uri.TryCreate(address.Text.Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Invalid address", Content = "Enter an http:// or https:// server address.", CloseButtonText = "OK" }.ShowAsync();
            return;
        }
        if (string.IsNullOrWhiteSpace(name.Text) || string.IsNullOrWhiteSpace(username.Text) || string.IsNullOrEmpty(password.Password)) return;

        var server = new MusicServer
        {
            Kind = kind.SelectedIndex == 0 ? MusicServerKind.Jellyfin : MusicServerKind.Subsonic,
            Name = name.Text.Trim(),
            Address = uri,
            Username = username.Text.Trim()
        };

        if (!await App.Services.TestServerAsync(server, password.Password))
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Connection failed", Content = "The server could not be reached or the credentials were refused.", CloseButtonText = "OK" }.ShowAsync();
            return;
        }

        await App.Services.AddServerAsync(server, password.Password);
        Refresh();
    }

    private async void EditServer_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not MusicServer server) return;
        var currentPassword = WindowsCredentialStore.Read(server.PasswordKey) ?? "";
        var kind = new ComboBox { ItemsSource = new[] { "Jellyfin", "Navidrome / Subsonic" }, SelectedIndex = server.Kind == MusicServerKind.Jellyfin ? 0 : 1 };
        var name = new TextBox { Text = server.Name, Header = "Name" };
        var address = new TextBox { Text = server.Address.ToString(), Header = "Address" };
        var username = new TextBox { Text = server.Username, Header = "Username" };
        var password = new PasswordBox { PlaceholderText = "Leave blank to keep current password", Header = "Password" };
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(kind); stack.Children.Add(name); stack.Children.Add(address); stack.Children.Add(username); stack.Children.Add(password);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Edit music server", Content = stack, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (!Uri.TryCreate(address.Text.Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return;
        var updated = server with { Kind = kind.SelectedIndex == 0 ? MusicServerKind.Jellyfin : MusicServerKind.Subsonic, Name = name.Text.Trim(), Address = uri, Username = username.Text.Trim() };
        var secret = string.IsNullOrEmpty(password.Password) ? currentPassword : password.Password;
        if (string.IsNullOrWhiteSpace(updated.Name) || string.IsNullOrWhiteSpace(updated.Username) || string.IsNullOrWhiteSpace(secret)) return;
        if (!await App.Services.TestServerAsync(updated, secret))
        {
            await new ContentDialog { XamlRoot = XamlRoot, Title = "Connection failed", Content = "The server could not be reached or the credentials were refused.", CloseButtonText = "OK" }.ShowAsync();
            return;
        }
        await App.Services.UpdateServerAsync(updated, secret);
        Refresh();
    }

    private void SourceVisibility_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing || sender is not ToggleSwitch toggle || toggle.Tag is not string key) return;
        LibrarySource? source = App.Services.Sources.Where(x => string.Equals(x.Key, key, StringComparison.OrdinalIgnoreCase)).Select(x => (LibrarySource?)x).FirstOrDefault();
        if (source is not { } value) return;
        App.Services.SetSourceHidden(value, !toggle.IsOn);
        Refresh();
    }

    private void RemoveServer_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is MusicServer server)
            App.Services.RemoveServer(server.Id);
    }

    private async void ClearCache_Click(object sender, RoutedEventArgs e)
    {
        RemoteCache.Empty();
        await RemoteCache.EnforceLimitAsync(App.Services.Settings.RemoteCacheLimitBytes);
        Refresh();
    }

    private async void ClearOffline_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Clear offline downloads?", Content = "All downloaded server tracks will be deleted.", PrimaryButtonText = "Clear", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            App.Services.Offline.RemoveAll();
            Refresh();
        }
    }

    private void Discord_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.ConfigureDiscord(DiscordToggle.IsOn, DiscordApplicationId.Text, DiscordArtworkToggle.IsOn);
    }

    private void DiscordArtwork_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.ConfigureDiscord(DiscordToggle.IsOn, DiscordApplicationId.Text, DiscordArtworkToggle.IsOn);
    }

    private void LastFm_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.ConfigureLastFm(LastFmToggle.IsOn, LastFmApiKey.Text, LastFmSecret.Password, LastFmSession.Password);
    }

    private void ListenBrainz_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.ConfigureListenBrainz(ListenBrainzToggle.IsOn, ListenBrainzServer.Text, ListenBrainzToken.Password);
    }

    private async void CastConnect_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(CastHost.Text)) return;
        try
        {
            await App.Services.Cast.ConnectAsync(CastHost.Text.Trim(), (int)(CastPort.Value > 0 ? CastPort.Value : 8009));
            CastStatus.Text = App.Services.Cast.Connected ? "Connected to Cast receiver." : "Connection failed.";
        }
        catch (Exception ex) { CastStatus.Text = ex.Message; }
    }

    private async void CastDiscover_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var devices = await App.Services.CastDiscovery.DiscoverAsync();
            if (devices.Count == 0) { CastStatus.Text = "No Google Cast devices found on the local network."; return; }
            CastStatus.Text = string.Join(" · ", devices.Select(d => $"{d.Name} ({d.Host}:{d.Port})"));
            CastHost.Text = devices[0].Host; CastPort.Value = devices[0].Port;
        }
        catch (Exception ex) { CastStatus.Text = ex.Message; }
    }

    private async void CastCurrent_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await App.Services.CastCurrentAsync(CastHost.Text.Trim());
            CastStatus.Text = "Current track sent to Cast receiver.";
        }
        catch (Exception ex) { CastStatus.Text = ex.Message; }
    }

    private async void CastPlay_Click(object sender, RoutedEventArgs e)
    {
        try { await App.Services.Cast.PlayAsync(); } catch (Exception ex) { CastStatus.Text = ex.Message; }
    }

    private async void CastPause_Click(object sender, RoutedEventArgs e)
    {
        try { await App.Services.Cast.PauseAsync(); } catch (Exception ex) { CastStatus.Text = ex.Message; }
    }

    private async void CastStop_Click(object sender, RoutedEventArgs e)
    {
        try { await App.Services.Cast.StopAsync(); } catch (Exception ex) { CastStatus.Text = ex.Message; }
    }

    private void RegisterAssociations_Click(object sender, RoutedEventArgs e)
    {
        FileAssociationService.EnsureRegistered();
        App.Services.UpdateIntegrationSettings(x => x with { FileAssociationsRegistered = true });
    }

    private static string FormatBytes(long bytes)
    {
        var value = (double)bytes;
        var units = new[] { "B", "KB", "MB", "GB", "TB" };
        var i = 0;
        while (value >= 1024 && i < units.Length - 1) { value /= 1024; i++; }
        return $"{value:0.##} {units[i]}";
    }
}
