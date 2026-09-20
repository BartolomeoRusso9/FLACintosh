using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace MusicPlayerWin.App.Controls;

/// <summary>
/// The playhead, as a line rather than a slider — port of Scrubber.swift.
/// Follows the pointer while dragging and only tells the player once, on
/// release: seeking on every intermediate value makes the decoder thrash.
/// </summary>
public sealed partial class Scrubber : UserControl
{
    private double _width = 210;
    private bool _dragging;
    private double _draggingFraction;
    private double _elapsed;
    private double _duration;

    /// <summary>Raised only when the pointer is released — the actual seek.</summary>
    public event EventHandler<double>? Seeked;

    public Scrubber()
    {
        InitializeComponent();
    }

    public void SetPosition(double elapsed, double duration)
    {
        _elapsed = elapsed;
        _duration = duration;
        if (!_dragging) UpdateVisual(Fraction);
    }

    private double Fraction => _duration > 0 ? Math.Clamp(_elapsed / _duration, 0, 1) : 0;

    private void RootGrid_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        _width = e.NewSize.Width > 0 ? e.NewSize.Width : _width;
        UpdateVisual(_dragging ? _draggingFraction : Fraction);
    }

    private void UpdateVisual(double fraction) => FillBorder.Width = Math.Max(0, _width * fraction);

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
        if (!_dragging) return;
        _dragging = false;
        RootGrid.ReleasePointerCapture(e.Pointer);
        if (_duration > 0) Seeked?.Invoke(this, _draggingFraction * _duration);
    }

    private void ApplyPointer(PointerRoutedEventArgs e)
    {
        var x = e.GetCurrentPoint(RootGrid).Position.X;
        _draggingFraction = _width > 0 ? Math.Clamp(x / _width, 0, 1) : 0;
        UpdateVisual(_draggingFraction);
    }
}
