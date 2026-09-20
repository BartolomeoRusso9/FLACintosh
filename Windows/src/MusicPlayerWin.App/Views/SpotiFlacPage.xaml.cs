using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using MusicPlayerWin.App.Services;

namespace MusicPlayerWin.App.Views;

public sealed partial class SpotiFlacPage : Page
{
    public SpotiFlacPage()
    {
        InitializeComponent();
        Loaded += (_, _) => RefreshStatus();
    }

    private void RefreshStatus()
    {
        var cli = App.Services.SpotiFlacCli;
        var server = App.Services.SpotiFlacServer;
        Status.Text = server.IsConfigured ? "Connected to SpotiFLAC server" : cli.ExecutablePath is not null ? $"Local CLI found{(cli.Version is null ? "" : $" ({cli.Version})")}" : "Not configured — use Configure server or install SpotiFLAC";
    }

    private async void Configure_Click(object sender, RoutedEventArgs e)
    {
        var address = new TextBox { Text = App.Services.Settings.Integrations.SpotiFlacAddress, PlaceholderText = "http://localhost:8765" };
        var token = new PasswordBox { PlaceholderText = "Access token" };
        var stack = new StackPanel { Spacing = 10 }; stack.Children.Add(new TextBlock { Text = "Server address" }); stack.Children.Add(address); stack.Children.Add(new TextBlock { Text = "Access token" }); stack.Children.Add(token);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Configure SpotiFLAC server", Content = stack, PrimaryButtonText = "Connect", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try { await App.Services.ConfigureSpotiFlacAsync(address.Text, token.Password); RefreshStatus(); }
        catch (Exception ex) { await new ContentDialog { XamlRoot = XamlRoot, Title = "Connection failed", Content = ex.Message, CloseButtonText = "OK" }.ShowAsync(); }
    }

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
    {
        Status.Text = "Checking latest SpotiFLAC version…";
        var latest = await App.Services.SpotiFlacCli.CheckLatestVersionAsync();
        if (latest is null) { Status.Text = "Could not read the latest SpotiFLAC version."; return; }
        Status.Text = App.Services.SpotiFlacCli.ExecutablePath is not null && App.Services.SpotiFlacCli.UpdateAvailable
            ? $"Update available: {latest} (installed {App.Services.SpotiFlacCli.Version})."
            : $"Latest SpotiFLAC: {latest}";
    }

    private void OpenTui_Click(object sender, RoutedEventArgs e)
    {
        var root = App.Services.Library.RootPath;
        if (!string.IsNullOrWhiteSpace(root)) App.Services.SpotiFlacCli.LaunchTui(root);
    }

    private async void Search_Click(object sender, RoutedEventArgs e) => await SearchAsync();
    private async void Query_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == Windows.System.VirtualKey.Enter) await SearchAsync(); }

    private async Task SearchAsync()
    {
        if (string.IsNullOrWhiteSpace(Query.Text)) return;
        try { Results.ItemsSource = await App.Services.SpotiFlacServer.SearchAsync(Query.Text.Trim()); Status.Text = $"{Results.Items.Count} results"; }
        catch (Exception ex) { Status.Text = ex.Message; }
    }

    private void Result_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not SpotiFlacResult result) return;
        App.MainWindow.ShowSpotiFlacTracklist(result);
    }

    private void Download_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not SpotiFlacResult result) return;
        App.Services.SpotiFlacServer.Enqueue(result);
        Status.Text = $"Download requested: {result.Title}";
    }
}
