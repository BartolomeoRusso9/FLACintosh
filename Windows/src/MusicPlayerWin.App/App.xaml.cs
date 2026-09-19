using Microsoft.UI.Xaml;
using MusicPlayerWin.App.Services;
using System.Threading.Tasks;

namespace MusicPlayerWin.App;

public partial class App : Microsoft.UI.Xaml.Application
{
    public static AppServices Services { get; private set; } = null!;

    public static MainWindow MainWindow { get; private set; } = null!;
    public static FirstRunService FirstRun { get; } = new();
    private static int _shutdownStarted;

    public static async Task ShutdownAsync()
    {
        if (Interlocked.Exchange(ref _shutdownStarted, 1) != 0) return;
        try { await Services.DisposeAsync(); }
        catch (Exception ex) { AppLog.Error("Shutdown failed.", ex); }
        finally { Services = null!; }
    }

    public App()
    {
        InitializeComponent();
        Services = new AppServices();
        Services.ErrorRaised += (_, message) => AppLog.Error($"Unhandled application service error: {message}");
        UnhandledException += (_, e) => AppLog.Error("WinUI unhandled exception.", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => AppLog.Error("AppDomain unhandled exception.", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { AppLog.Error("Unobserved task exception.", e.Exception); e.SetObserved(); };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindow = new MainWindow();
        MainWindow.Activate();
        if (Services.Settings.Integrations.FileAssociationsRegistered)
            FileAssociationService.EnsureRegistered();
        _ = Services.ReloadAllSourcesAsync();
        if (FirstRun.IsFirstRun)
            MainWindow.DispatcherQueue.TryEnqueue(async () => await MainWindow.ShowFirstRunAsync());

        var argument = args.Arguments?.Trim().Trim('"');
        if (!string.IsNullOrWhiteSpace(argument) && File.Exists(argument))
            _ = Services.PlayFileAsync(argument);
    }
}
