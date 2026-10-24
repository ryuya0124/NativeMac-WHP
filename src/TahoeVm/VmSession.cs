using System.Diagnostics;
using System.Text;
using System.IO.Pipes;
using System.Text.Json;

namespace TahoeVm;

internal sealed class VmSession
{
    private Process? _process;
    private readonly object _inputGate = new();
    private CancellationTokenSource? _control;
    private readonly object _stateGate = new();
    private VmPowerState _state = VmPowerState.Starting;
    private Action<int?>? _saveState;
    public event Action<string>? Output;
    public event Action<int>? Exited;
    public event Action<VmPowerState>? PowerStateChanged;

    private void SetState(VmPowerState state, int? exitCode = null)
    {
        lock (_stateGate) { _state = state; _saveState?.Invoke(exitCode); }
        PowerStateChanged?.Invoke(state);
    }

    public void Start(int memoryGiB, int processors, string displayResolution)
    {
        if (displayResolution is not ("1920x1080" or "2560x1440" or "3840x2160"))
            throw new ArgumentException("未対応の解像度です。", nameof(displayResolution));
        if (memoryGiB is < 1 or > 256 || processors is < 1 or > 64)
            throw new ArgumentOutOfRangeException(nameof(memoryGiB), "VMの設定上限は256 GiB・64コアです。");
        if (_process is { HasExited: false }) throw new InvalidOperationException("VMは実行中です。");
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "scripts", "Start-VM.ps1")))
            directory = directory.Parent;
        if (directory is null) throw new DirectoryNotFoundException("プロジェクト内のartifacts/appから起動してください。");
        var root = directory.FullName;
        var logGate = new object();
        var logPath = Path.Combine(root, "artifacts", "vm-launcher.log");
        Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
        File.WriteAllText(logPath, "");
        void Receive(string? line)
        {
            if (line is null) return;
            lock (logGate) File.AppendAllText(logPath, line + "\n", Encoding.UTF8);
            if (VmPowerProtocol.Read(line) is { } state) SetState(state);
            Output?.Invoke(line);
        }
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe"),
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var value in new[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            Path.Combine(root, "scripts", "Start-VM.ps1"), "-MemoryGiB", memoryGiB.ToString(),
            "-Processors", processors.ToString(), "-Gpu", "-DisplayResolution", displayResolution }) start.ArgumentList.Add(value);
        var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => Receive(e.Data);
        process.ErrorDataReceived += (_, e) => Receive(e.Data);
        var control = new CancellationTokenSource();
        process.Exited += (_, _) => _ = Task.Run(() =>
        {
            // Drain redirected output before reporting exit, so the final power
            // event cannot be delivered after Stopped/Faulted to the UI.
            process.WaitForExit();
            control.Cancel();
            SetState(process.ExitCode == 0 ? VmPowerState.Stopped : VmPowerState.Faulted, process.ExitCode);
            Exited?.Invoke(process.ExitCode);
        });
        if (!process.Start()) throw new InvalidOperationException("VMプロセスを開始できません。");
        _process = process;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        // Local diagnostics API: restricted to this Windows account. It carries
        // VMM commands, never shell commands or input to other applications.
        _control = control;
        string pipeName = $"NativeMac-{Environment.ProcessId}";
        Directory.CreateDirectory(Path.Combine(root, "artifacts"));
        var startedAt = DateTimeOffset.Now;
        lock (_stateGate)
        {
            _saveState = code => File.WriteAllText(Path.Combine(root, "artifacts", "vm-session.json"),
                JsonSerializer.Serialize(new { appPid = Environment.ProcessId, launcherPid = process.Id,
                    controlPipe = pipeName, memoryGiB, processors, displayResolution,
                    state = _state.ToString().ToLowerInvariant(), exitCode = code, startedAt,
                    updatedAt = DateTimeOffset.Now, guestGpuVerification = "not_run_this_session" }));
            _saveState(null);
        }
        _ = RunControl(pipeName, _control.Token);
    }

    public void Pause() => SendCommand("pause");
    public void Resume() => SendCommand("resume");

    public void PowerOff()
    {
        if (_process is not { HasExited: false } process) return;
        SendCommand("quit");
    }

    private void SendCommand(string command)
    {
        lock (_inputGate)
        {
            if (_process is not { HasExited: false } process) return;
            process.StandardInput.WriteLine(command);
            process.StandardInput.Flush();
        }
    }

    private async Task RunControl(string name, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                using var pipe = new NamedPipeServerStream(name, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(token);
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                while (await reader.ReadLineAsync(token) is { } line)
                {
                    string command = line.Split(' ', 2)[0];
                    if (command is "inspect" or "read-memory" or "pause" or "resume" or "reset" or "quit")
                        SendCommand(line);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException error) { Output?.Invoke($"VM control channel: {error.Message}"); }
    }
}
