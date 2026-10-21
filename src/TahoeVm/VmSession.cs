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
    public event Action<string>? Output;
    public event Action<int>? Exited;

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
        process.Exited += (_, _) => { _control?.Cancel(); Exited?.Invoke(process.ExitCode); };
        if (!process.Start()) throw new InvalidOperationException("VMプロセスを開始できません。");
        _process = process;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        // Local diagnostics API: restricted to this Windows account. It carries
        // VMM commands, never shell commands or input to other applications.
        _control = new CancellationTokenSource();
        string pipeName = $"NativeMac-{Environment.ProcessId}";
        Directory.CreateDirectory(Path.Combine(root, "artifacts"));
        File.WriteAllText(Path.Combine(root, "artifacts", "vm-session.json"),
            JsonSerializer.Serialize(new { appPid = Environment.ProcessId, launcherPid = process.Id,
                controlPipe = pipeName, memoryGiB, processors, displayResolution, guestGpuVerification = "not_run_this_session" }));
        _ = RunControl(pipeName, _control.Token);
    }

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
