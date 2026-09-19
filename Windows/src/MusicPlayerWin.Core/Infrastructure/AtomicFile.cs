using System.Text;

namespace MusicPlayerWin.Core.Infrastructure;

/// <summary>Small atomic file helper used for JSON/configuration persistence.</summary>
public static class AtomicFile
{
    public static void WriteAllText(string path, string contents)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, contents, new UTF8Encoding(false));
            if (File.Exists(fullPath))
                File.Move(temporary, fullPath, true);
            else
                File.Move(temporary, fullPath);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
        }
    }
}
