using Microsoft.UI.Xaml.Media.Imaging;
using System.Collections.Concurrent;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

namespace MusicPlayerWin.App.Services;

public static class BitmapCacheService
{
    private static readonly ConcurrentDictionary<string, BitmapImage> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static async Task<BitmapImage?> FromBytesAsync(byte[]? bytes, string key)
    {
        if (bytes is null || bytes.Length == 0) return null;
        if (Cache.TryGetValue(key, out var existing)) return existing;
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            Cache[key] = bitmap;
            return bitmap;
        }
        catch { return null; }
    }

    public static void Clear() => Cache.Clear();
}
