using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MusicPlayerWin.Core.Library;

namespace MusicPlayerWin.App.Controls;

/// <summary>
/// Where a record or a track lives: this PC's folder, or which server —
/// port of SourceBadge.swift. Two colours, not one per source: local is
/// blue, a server is orange.
/// </summary>
public sealed partial class SourceBadge : UserControl
{
    private static readonly SolidColorBrush LocalBrush = new(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0x0A, 0x84, 0xFF));
    private static readonly SolidColorBrush ServerBrush = new(Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xFF, 0x9F, 0x0A));

    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(
        nameof(Source), typeof(LibrarySource?), typeof(SourceBadge), new PropertyMetadata(null, OnSourceChanged));

    public LibrarySource? Source
    {
        get => (LibrarySource?)GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public SourceBadge()
    {
        InitializeComponent();
    }

    private static void OnSourceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((SourceBadge)d).Refresh();

    private void Refresh()
    {
        // Only worth telling apart once there's more than one source — with
        // a single folder or server the question "local or server?" has
        // only one answer, and the badge is noise.
        if (Source is not { } source || App.Services.Sources.Count <= 1)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        var tint = source.IsFolder ? LocalBrush : ServerBrush;
        Root.Background = new SolidColorBrush(tint.Color) { Opacity = 0.14 };
        Label.Foreground = tint;
        Label.Text = App.Services.Library.SourceName(source);
    }
}
