using Microsoft.UI.Xaml;
using Windows.Foundation;

namespace MusicPlayerWin.App.Controls;

/// <summary>Simple wrapping panel for lyric syllables, keeping each TextBlock independently animatable.</summary>
public sealed class SyllableFlowPanel : Panel
{
    public double Spacing
    {
        get => (double)GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        nameof(Spacing), typeof(double), typeof(SyllableFlowPanel), new PropertyMetadata(2d));

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? double.PositiveInfinity : Math.Max(0, availableSize.Width);
        var x = 0d;
        var rowHeight = 0d;
        var totalHeight = 0d;
        foreach (var child in Children)
        {
            child.Measure(new Size(width, double.PositiveInfinity));
            var desired = child.DesiredSize;
            if (x > 0 && x + desired.Width > width)
            {
                totalHeight += rowHeight + Spacing;
                x = 0;
                rowHeight = 0;
            }
            x += desired.Width;
            rowHeight = Math.Max(rowHeight, desired.Height);
        }
        totalHeight += rowHeight;
        var desiredWidth = double.IsInfinity(availableSize.Width) ? Children.Cast<UIElement>().Select(c => c.DesiredSize.Width).DefaultIfEmpty().Max() : availableSize.Width;
        return new Size(desiredWidth, totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var x = 0d;
        var y = 0d;
        var rowHeight = 0d;
        foreach (var child in Children)
        {
            var desired = child.DesiredSize;
            if (x > 0 && x + desired.Width > finalSize.Width)
            {
                y += rowHeight + Spacing;
                x = 0;
                rowHeight = 0;
            }
            child.Arrange(new Rect(x, y, desired.Width, desired.Height));
            x += desired.Width;
            rowHeight = Math.Max(rowHeight, desired.Height);
        }
        return finalSize;
    }
}
