using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace TahoeVm;

public sealed partial class MainPage : Page
{
    private IntPtr _renderer;
    private readonly DispatcherTimer _renderTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Stopwatch _time = Stopwatch.StartNew();
    private readonly List<object> _reports = [];
    private uint _frames;
    private bool _closed;
    private bool _started;
    private VmSession? _vm;

    public MainPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        _renderTimer.Tick += (_, _) => Render();
    }
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_started) return;
        _started = true;
        var args = Environment.GetCommandLineArgs();
        if (args.Contains("--start-vm"))
        {
            try
            {
                int memoryIndex = Array.IndexOf(args, "--memory");
                int cpuIndex = Array.IndexOf(args, "--processors");
                if (memoryIndex >= 0) VmMemory.Value = int.Parse(args[memoryIndex + 1]);
                if (cpuIndex >= 0) VmProcessors.Value = int.Parse(args[cpuIndex + 1]);
                int resolutionIndex = Array.IndexOf(args, "--resolution");
                if (resolutionIndex >= 0)
                {
                    string resolution = args[resolutionIndex + 1];
                    VmResolution.SelectedItem = VmResolution.Items.Cast<ComboBoxItem>()
                        .FirstOrDefault(item => (string)item.Tag == resolution)
                        ?? throw new ArgumentException("未対応の解像度です。");
                }
                CpuState.Text = "WHP VMを使用";
                CpuDetails.Text = "単体プローブは実行していません。";
                StartVm_Click(this, new RoutedEventArgs());
            }
            catch (Exception error) { VmStatus.Text = error.Message; }
            return;
        }
        try
        {
            // Borrow the WinRT interface; native code takes its own QI reference.
            var panel = ((WinRT.IWinRTObject)GpuPanel).NativeObject.ThisPtr;
            var result = NativeEngine.CreateGpu(panel);
            _renderer = result.Handle;
            _frames = 1;
            _reports.Add(result.Report);
            AppendLog("GPU", result.Json);
            GpuState.Text = "ハードウェア描画";
            GpuDetails.Text = result.Report.Adapter;
            GpuMilestone.Text = "✓ ホストGPU：検証成功";
            _renderTimer.Start();
        }
        catch (Exception error)
        {
            GpuState.Text = "描画を開始できません";
            GpuError.Text = error.Message;
            GpuError.Visibility = Visibility.Visible;
            GpuMilestone.Text = "× ホストGPU：検証失敗";
            _reports.Add(new { kind = "gpuError", error = error.ToString() });
            AppendLog("GPU ERROR", error.Message);
        }
        await TestCpu();
        int reportIndex = Array.IndexOf(args, "--smoke-report");
        if (reportIndex >= 0 && reportIndex + 1 < args.Length)
        {
            await Task.Delay(500);
            var path = Path.GetFullPath(args[reportIndex + 1]);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await File.WriteAllTextAsync(path, JsonSerializer.Serialize(new
            {
                reports = _reports, presentedFrames = _frames,
                hostVisible = XamlRoot?.IsHostVisible,
                viewWidth = ActualWidth, viewHeight = ActualHeight,
                macOsBooted = false, guestGpuAccelerated = false
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
    }
    private void Render()
    {
        if (_renderer == IntPtr.Zero || _closed) return;
        int hr = NativeEngine.NmGpuDraw(_renderer, (float)_time.Elapsed.TotalSeconds);
        if (hr < 0)
        {
            _renderTimer.Stop();
            GpuState.Text = "GPU描画が停止しました";
            GpuError.Text = $"Direct3D error 0x{hr:X8}。CPU描画には切り替えません。";
            GpuError.Visibility = Visibility.Visible;
            AppendLog("GPU ERROR", GpuError.Text);
        }
        else ++_frames;
    }
    private async Task TestCpu()
    {
        if (!CpuButton.IsEnabled || _closed) return;
        CpuButton.IsEnabled = false;
        CpuState.Text = "ゲストを実行中";
        CpuProgress.Visibility = Visibility.Visible;
        try
        {
            var result = await Task.Run(NativeEngine.TestCpu);
            if (_closed) return;
            _reports.Add(result.Report);
            AppendLog("CPU", result.Json);
            bool passed = result.Report.Status == "passed";
            CpuState.Text = passed ? "x64実行に成功" : "検証できませんでした";
            CpuDetails.Text = passed
                ? $"{result.Report.GuestVendor}\nLong Mode / AVX2: {result.Report.GuestAvx2}\n{result.Report.ElapsedMs} ms / I/O exits: {result.Report.IoExits}"
                : $"{result.Report.Stage}\n{result.Report.Hresult}";
            CpuMilestone.Text = passed ? "✓ CPU実行：検証成功" : "× CPU実行：検証失敗";
            Summary.Text = passed
                ? "このCPU単体テストで64ビット計算、RAM書き込み、I/O捕捉、停止を検証しました。macOS復旧環境の起動は別のWHPバックエンドで検証します。"
                : "Windows Hypervisor Platformの状態と下のエラーを確認してください。";
        }
        catch (Exception error)
        {
            CpuState.Text = "エンジンを実行できません";
            CpuDetails.Text = error.Message;
            _reports.Add(new { kind = "cpuError", error = error.ToString() });
            AppendLog("CPU ERROR", error.ToString());
        }
        finally
        {
            CpuButton.IsEnabled = true;
            CpuProgress.Visibility = Visibility.Collapsed;
        }
    }
    private async void TestCpu_Click(object sender, RoutedEventArgs e) => await TestCpu();
    private void StartVm_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            int memory = checked((int)VmMemory.Value);
            int processors = checked((int)VmProcessors.Value);
            string resolution = (string)((ComboBoxItem)VmResolution.SelectedItem).Tag;
            _renderTimer.Stop();
            if (_renderer != IntPtr.Zero) NativeEngine.NmGpuDestroy(_renderer);
            _renderer = IntPtr.Zero;
            GpuState.Text = "VMのGPUへ切り替え";
            GpuCaption.Text = "ゲスト画面は別ウィンドウに表示";
            GpuCaptionDetails.Text = "このウィンドウでVMのリソースと電源を管理できます。";
            _vm = new VmSession();
            _vm.Output += line => DispatcherQueue.TryEnqueue(() =>
            {
                if (_closed) return;
                LogBox.Text = (LogBox.Text + line + "\n");
                if (LogBox.Text.Length > 24000) LogBox.Text = LogBox.Text[^24000..];
            });
            _vm.Exited += code => DispatcherQueue.TryEnqueue(() =>
            {
                if (_closed) return;
                VmStatus.Text = $"VMが終了しました (code {code})";
                VmStartButton.IsEnabled = true;
                VmStopButton.IsEnabled = false;
                VmMemory.IsEnabled = VmProcessors.IsEnabled = true;
                VmResolution.IsEnabled = true;
                CpuButton.IsEnabled = true;
            });
            _vm.Start(memory, processors, resolution);
            VmStatus.Text = $"WHPで起動中 · {memory} GiB / {processors}コア / {resolution}";
            VmStartButton.IsEnabled = false;
            VmStopButton.IsEnabled = true;
            VmMemory.IsEnabled = VmProcessors.IsEnabled = false;
            VmResolution.IsEnabled = false;
            CpuButton.IsEnabled = false;
        }
        catch (Exception error) { VmStatus.Text = error.Message; }
    }
    private void StopVm_Click(object sender, RoutedEventArgs e)
    {
        try { _vm?.PowerOff(); VmStatus.Text = "VMを終了しています…"; }
        catch (Exception error) { VmStatus.Text = error.Message; }
    }
    private void AppendLog(string label, string json)
    {
        string value = json;
        try { using var doc = JsonDocument.Parse(json); value = JsonSerializer.Serialize(doc.RootElement, new JsonSerializerOptions { WriteIndented = true }); }
        catch (JsonException) { }
        LogBox.Text += $"[{label}] {DateTime.Now:HH:mm:ss}\n{value}\n\n";
    }
    private async void SaveLog_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FileSavePicker { SuggestedFileName = "NativeMac-hardware-test" };
            picker.FileTypeChoices.Add("実行ログ", new List<string> { ".txt" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
            var file = await picker.PickSaveFileAsync();
            if (file is not null) await Windows.Storage.FileIO.WriteTextAsync(file, LogBox.Text);
        }
        catch (Exception error) { AppendLog("SAVE ERROR", error.Message); }
    }
    internal void StopRendering()
    {
        _closed = true;
        try { _vm?.PowerOff(); } catch (IOException) { }
        _renderTimer.Stop();
        if (_renderer == IntPtr.Zero) return;
        NativeEngine.NmGpuDestroy(_renderer);
        _renderer = IntPtr.Zero;
    }
}
