using Microsoft.UI.Xaml;

namespace TahoeVm;

public partial class App : Application
{
    internal static MainWindow? Main { get; private set; }
    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NativeMac");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "crash.log"), e.Exception.ToString());
        };
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Main = new MainWindow();
        Main.Activate();
        Main.AppWindow.Show();
    }
}
