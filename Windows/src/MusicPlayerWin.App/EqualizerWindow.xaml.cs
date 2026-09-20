using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls.Primitives;
using MusicPlayerWin.App.Controls;
using MusicPlayerWin.Core.Audio;

namespace MusicPlayerWin.App;

/// <summary>
/// The equalizer as its own window — ten bands, the presets, and the
/// loudness settings that sit next to it, matching FLACintosh's
/// WindowGroup(id: "equalizer") / EqualizerView.swift rather than being
/// embedded inline in Settings.
/// </summary>
public sealed partial class EqualizerWindow : Window
{
    private bool _refreshing;
    private readonly VerticalGainSlider[] _eqSliders;

    public EqualizerWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(660, 520));
        _eqSliders = [Eq0, Eq1, Eq2, Eq3, Eq4, Eq5, Eq6, Eq7, Eq8, Eq9];
        PresetCombo.ItemsSource = AudioEffectsSettings.Presets.Keys.ToArray();
        Refresh();
        App.Services.SettingsChanged += ServicesOnChanged;
        Closed += (_, _) => App.Services.SettingsChanged -= ServicesOnChanged;
    }

    private void ServicesOnChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    private void Refresh()
    {
        _refreshing = true;
        var effects = App.Services.Effects.Normalize();
        EqualizerToggle.IsOn = effects.EqualizerEnabled;
        for (var i = 0; i < _eqSliders.Length; i++)
            _eqSliders[i].Value = i < effects.Gains.Length ? effects.Gains[i] : 0;
        PresetCombo.SelectedItem = AudioEffectsSettings.Presets.ContainsKey(effects.PresetName) ? effects.PresetName : null;
        EqHeadroom.Text = effects.EqualizerEnabled && effects.EqualizerHeadroomDb < 0
            ? $"Automatic headroom: {effects.EqualizerHeadroomDb:0.0} dB"
            : "Headroom: 0 dB";
        ReplayGainCombo.SelectedIndex = effects.ReplayGain switch
        {
            AudioEffectsSettings.ReplayGainMode.Track => 1,
            AudioEffectsSettings.ReplayGainMode.Album => 2,
            _ => 0
        };
        ReplayGainPreampSlider.Value = effects.ReplayGainPreamp;
        ReplayGainPreampValue.Text = $"Preamp: {effects.ReplayGainPreamp:+0.0;-0.0;0.0} dB";
        _refreshing = false;
    }

    private void Equalizer_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        App.Services.SetAudioEffects(App.Services.Effects with { EqualizerEnabled = EqualizerToggle.IsOn });
    }

    private void EqBand_ValueChanged(object? sender, double newValue)
    {
        if (_refreshing || sender is not VerticalGainSlider slider || slider.Tag is not string tag || !int.TryParse(tag, out var band)) return;
        App.Services.SetEqualizerGain(band, newValue);
    }

    private void PresetCombo_SelectionChanged(object sender, Microsoft.UI.Xaml.Controls.SelectionChangedEventArgs e)
    {
        if (_refreshing || PresetCombo.SelectedItem is not string preset) return;
        App.Services.ApplyEqualizerPreset(preset);
    }

    private void ReplayGainCombo_SelectionChanged(object sender, Microsoft.UI.Xaml.Controls.SelectionChangedEventArgs e)
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
}
