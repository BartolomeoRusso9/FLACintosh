using System.Text.Json;
using MusicPlayerWin.Core.Audio;
using MusicPlayerWin.Core.Infrastructure;

namespace MusicPlayerWin.Core;

public sealed record IntegrationSettings
{
    public bool DiscordEnabled { get; init; }
    public string DiscordApplicationId { get; init; } = "";
    public bool DiscordArtwork { get; init; } = true;
    public bool LastFmEnabled { get; init; }
    public string LastFmApiKey { get; init; } = "";
    public string LastFmSharedSecret { get; init; } = "";
    public bool ListenBrainzEnabled { get; init; }
    public string ListenBrainzServer { get; init; } = "https://api.listenbrainz.org";
    public string SpotiFlacAddress { get; init; } = "";
    public string SpotiFlacExecutable { get; init; } = "";
    public bool FileAssociationsRegistered { get; init; }
}

public sealed record AppSettings
{
    public int SchemaVersion { get; init; } = SettingsMigration.CurrentSchema;
    public string? LibraryRoot { get; init; }
    public bool AutoPlay { get; init; } = true;
    public bool Crossfade { get; init; }
    public long RemoteCacheLimitBytes { get; init; } = 2L * 1024 * 1024 * 1024;
    public bool StartWithWindows { get; init; }
    public bool MinimizeToTray { get; init; }
    public string Theme { get; init; } = "System";
    public AudioEffectsSettings Effects { get; init; } = AudioEffectsSettings.Default;
    public IntegrationSettings Integrations { get; init; } = new();
}

public sealed class SettingsStore
{
    public const int CurrentSchema = 3;
    private readonly object _gate = new();
    private readonly string _path;
    public AppSettings Current { get; private set; }

    public SettingsStore(string? root = null)
    {
        root ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MusicPlayerWin");
        Directory.CreateDirectory(root);
        _path = Path.Combine(root, "settings.json");
        Current = Load();
    }

    public void Update(Func<AppSettings, AppSettings> change)
    {
        lock (_gate)
        {
            Current = Migrate(change(Current)) with { SchemaVersion = CurrentSchema };
            AtomicFile.WriteAllText(_path, JsonSerializer.Serialize(Current, new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    private AppSettings Load()
    {
        try
        {
            var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new AppSettings();
            return Migrate(loaded);
        }
        catch { return new AppSettings { SchemaVersion = CurrentSchema }; }
    }

    private static AppSettings Migrate(AppSettings settings)
    {
        var migrated = SettingsMigration.Apply(settings);
        var effects = (migrated.Effects ?? AudioEffectsSettings.Default).Normalize();
        var integrations = migrated.Integrations ?? new IntegrationSettings();
        var theme = migrated.Theme is "System" or "Light" or "Dark" ? migrated.Theme : "System";
        var cache = migrated.RemoteCacheLimitBytes < 128 * 1024 * 1024 ? 2L * 1024 * 1024 * 1024 : migrated.RemoteCacheLimitBytes;
        return migrated with { SchemaVersion = CurrentSchema, Effects = effects, Integrations = integrations, Theme = theme, RemoteCacheLimitBytes = cache };
    }
}
