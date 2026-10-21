using Microsoft.UI.Xaml;

namespace TahoeVm;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 900));
        RootFrame.Navigate(typeof(MainPage));
        Closed += (_, _) => (RootFrame.Content as MainPage)?.StopRendering();
    }
}
