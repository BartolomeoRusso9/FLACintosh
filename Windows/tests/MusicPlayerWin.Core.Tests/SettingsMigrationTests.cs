using MusicPlayerWin.Core;
using MusicPlayerWin.Core.Audio;

namespace MusicPlayerWin.Core.Tests;

public sealed class SettingsMigrationTests
{
    [Fact]
    public void LegacyCrossfadeIsPromotedIntoEffects()
    {
        var legacy = new AppSettings { SchemaVersion = 2, Crossfade = true, Effects = AudioEffectsSettings.Default };
        var migrated = SettingsMigration.Apply(legacy);
        Assert.Equal(SettingsMigration.CurrentSchema, migrated.SchemaVersion);
        Assert.True(migrated.Effects.Crossfade);
    }

    [Fact]
    public void CurrentSettingsRemainUnchanged()
    {
        var current = new AppSettings { SchemaVersion = SettingsMigration.CurrentSchema, Effects = AudioEffectsSettings.Default };
        var migrated = SettingsMigration.Apply(current);
        Assert.False(migrated.Effects.Crossfade);
    }
}
