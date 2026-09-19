using MusicPlayerWin.Core.Metadata;

namespace MusicPlayerWin.Core.Tests;

public sealed class MetadataEditorTests
{
    [Fact]
    public void RejectsRemoteUrls()
    {
        var editor = new AudioMetadataEditor();
        Assert.Throws<ArgumentException>(() => editor.Read(new Uri("https://example.com/song.flac")));
    }
}
