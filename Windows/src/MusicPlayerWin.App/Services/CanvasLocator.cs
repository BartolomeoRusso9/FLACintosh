namespace MusicPlayerWin.App.Services;

public static class CanvasLocator
{
    private static readonly string[] Extensions = [".mp4", ".m4v", ".mov"];
    public static string? Find(string? localAudioPath)
    {
        if (string.IsNullOrWhiteSpace(localAudioPath)) return null;
        var basePath = Path.Combine(Path.GetDirectoryName(localAudioPath) ?? "", Path.GetFileNameWithoutExtension(localAudioPath));
        return Extensions.Select(ext => basePath + ext).FirstOrDefault(File.Exists);
    }
}
