namespace MusicPlayerWin.Core;

/// <summary>Small, forward-compatible migration layer for persisted app settings.
/// It intentionally keeps unknown/removed fields out of the runtime model while
/// preserving values that existed in earlier schema revisions.</summary>
public static class SettingsMigration
{
    public const int CurrentSchema = 3;
    public static AppSettings Apply(AppSettings settings)
    {
        // Schema 1/2 stored Crossfade as a top-level flag in some development
        // builds. Prefer an explicitly configured Effects.Crossfade value, but
        // promote the legacy flag when effects still have their defaults.
        var effects = settings.Effects ?? Audio.AudioEffectsSettings.Default;
        if (settings.SchemaVersion < 3 && settings.Crossfade && !effects.Crossfade)
            effects = effects with { Crossfade = true };

        return settings with { Effects = effects };
    }
}
