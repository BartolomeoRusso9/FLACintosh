namespace MusicPlayerWin.Core.Audio;

public sealed class AudioErrorEventArgs(Exception exception) : EventArgs
{
    public Exception Exception { get; } = exception;
}
