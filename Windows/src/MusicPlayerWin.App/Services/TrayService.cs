using System.Drawing;
using Forms = System.Windows.Forms;

namespace MusicPlayerWin.App.Services;

public sealed class TrayService : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly Action _show;
    private readonly Action _toggle;
    private readonly Action _next;
    private readonly Action _previous;
    private readonly Action _exit;

    public TrayService(Action show, Action toggle, Action next, Action previous, Action exit, string iconPath)
    {
        _show = show; _toggle = toggle; _next = next; _previous = previous; _exit = exit;
        _icon = new Forms.NotifyIcon
        {
            Text = "MusicPlayerWin",
            Icon = File.Exists(iconPath) ? new Icon(iconPath) : SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };
        _icon.DoubleClick += (_, _) => _show();
        _icon.ContextMenuStrip.Items.Add("Show player", null, (_, _) => _show());
        _icon.ContextMenuStrip.Items.Add("Previous", null, (_, _) => _previous());
        _icon.ContextMenuStrip.Items.Add("Play / Pause", null, (_, _) => _toggle());
        _icon.ContextMenuStrip.Items.Add("Next", null, (_, _) => _next());
        _icon.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
        _icon.ContextMenuStrip.Items.Add("Exit", null, (_, _) => _exit());
    }

    public void Dispose() => _icon.Dispose();
}
