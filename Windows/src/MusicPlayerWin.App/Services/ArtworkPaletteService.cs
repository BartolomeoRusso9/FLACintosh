using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace MusicPlayerWin.App.Services;

public readonly record struct PaletteColor(byte R, byte G, byte B)
{
    public string Hex => $"#{R:X2}{G:X2}{B:X2}";
}

public static class ArtworkPaletteService
{
    public static async Task<PaletteColor?> ExtractAsync(byte[] data, CancellationToken cancellationToken = default)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(data.AsBuffer());
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var transform = new BitmapTransform { ScaledWidth = 32, ScaledHeight = 32 };
            var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Ignore, transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            var bytes = pixels.DetachPixelData();
            if (bytes.Length < 4) return null;
            double r = 0, g = 0, b = 0, weight = 0;
            for (var i = 0; i + 3 < bytes.Length; i += 4)
            {
                var rr = bytes[i] / 255.0; var gg = bytes[i + 1] / 255.0; var bb = bytes[i + 2] / 255.0;
                var saturation = Math.Max(rr, Math.Max(gg, bb)) - Math.Min(rr, Math.Min(gg, bb));
                var w = 0.2 + saturation;
                r += rr * w; g += gg * w; b += bb * w; weight += w;
            }
            return weight <= 0 ? null : new PaletteColor((byte)Math.Round(r / weight * 255), (byte)Math.Round(g / weight * 255), (byte)Math.Round(b / weight * 255));
        }
        catch { return null; }
    }
}
