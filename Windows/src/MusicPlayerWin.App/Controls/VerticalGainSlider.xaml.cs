using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace MusicPlayerWin.App.Controls;

/// <summary>
/// A slider standing up, the way an equalizer's are — geometric port of the
/// private VerticalSlider in EqualizerView.swift: a capsule track, a fill
/// from the 0 dB line to the knob, and a white circular knob. Drag to set,
/// double-tap to reset to 0 dB.
/// </summary>
public sealed partial class VerticalGainSlider : UserControl
{
    private const double Minimum = -12;
    private const double Maximum = 12;

    private bool _suppressEvent;
    private bool _dragging;
    private double _height = 150;

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(VerticalGainSlider), new PropertyMetadata(0.0, OnValueChanged));

    public double Value
    {
        get => (double)GetValue(ValueProperty);
        set => SetValue(ValueProperty, System.Math.Clamp(value, Minimum, Maximum));
    }

    /// <summary>Raised only for user-driven changes (drag or double-tap reset), not programmatic ones.</summary>
    public event EventHandler<double>? ValueChanged;

    public VerticalGainSlider()
    {
        InitializeComponent();
        Loaded += (_, _) => UpdateVisual();
    }

    /// <summary>Sets the value without raising ValueChanged — for refreshing the UI from the model.</summary>
    public void SetValueSilently(double value)
    {
        _suppressEvent = true;
        Value = value;
        _suppressEvent = false;
    }

    private static void OnValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var control = (VerticalGainSlider)d;
        control.UpdateVisual();
        if (!control._suppressEvent) control.ValueChanged?.Invoke(control, (double)e.NewValue);
    }

    private void RootGrid_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        _height = e.NewSize.Height > 0 ? e.NewSize.Height : _height;
        UpdateVisual();
    }

    private void UpdateVisual()
    {
        var height = _height;
        var fraction = (Value - Minimum) / (Maximum - Minimum);
        var y = height * (1 - fraction);
        var centre = height / 2;

        Knob.Margin = new Thickness(0, System.Math.Max(0, y - 8), 0, 0);
        CenterLine.Margin = new Thickness(0, centre, 0, 0);

        var top = System.Math.Min(y, centre);
        var fillHeight = System.Math.Abs(y - centre);
        FillBorder.Margin = new Thickness(0, top, 0, 0);
        FillBorder.Height = System.Math.Max(0, fillHeight);
    }

    private void RootGrid_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _dragging = true;
        RootGrid.CapturePointer(e.Pointer);
        ApplyPointer(e);
    }

    private void RootGrid_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging) ApplyPointer(e);
    }

    private void RootGrid_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        _dragging = false;
        RootGrid.ReleasePointerCapture(e.Pointer);
    }

    private void ApplyPointer(PointerRoutedEventArgs e)
    {
        var y = e.GetCurrentPoint(RootGrid).Position.Y;
        var clamped = System.Math.Clamp(y, 0, _height);
        var fraction = 1 - clamped / _height;
        var raw = Minimum + fraction * (Maximum - Minimum);
        Value = System.Math.Round(raw * 2) / 2;
    }

    private void RootGrid_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => Value = 0;
}
