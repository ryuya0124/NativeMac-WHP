using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace TahoeVm;

internal static class NativeEngine
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    [DllImport("NativeMac.WHP.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NmRunCpuProbe([Out] byte[] report, uint capacity);
    [DllImport("NativeMac.WHP.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NmGpuCreate(IntPtr panel, out IntPtr handle, [Out] byte[] report, uint capacity);
    [DllImport("NativeMac.WHP.dll", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int NmGpuDraw(IntPtr handle, float elapsed);
    [DllImport("NativeMac.WHP.dll", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void NmGpuDestroy(IntPtr handle);

    private static string Decode(byte[] buffer)
    {
        int length = Array.IndexOf(buffer, (byte)0);
        return Encoding.UTF8.GetString(buffer, 0, length < 0 ? buffer.Length : length);
    }
    internal static (CpuReport Report, string Json) TestCpu()
    {
        var buffer = new byte[16384];
        NmRunCpuProbe(buffer, (uint)buffer.Length);
        string json = Decode(buffer);
        return (JsonSerializer.Deserialize<CpuReport>(json, JsonOptions) ?? throw new InvalidDataException("CPU report missing"), json);
    }
    internal static (GpuReport Report, string Json, IntPtr Handle) CreateGpu(IntPtr panel)
    {
        var buffer = new byte[16384];
        int hr = NmGpuCreate(panel, out var handle, buffer, (uint)buffer.Length);
        string json = Decode(buffer);
        try
        {
            var report = JsonSerializer.Deserialize<GpuReport>(json, JsonOptions) ?? throw new InvalidDataException("GPU report missing");
            if (hr < 0) throw new InvalidOperationException($"GPU: {report.Stage} ({report.Hresult})。CPU描画への切り替えは行いません。");
            return (report, json, handle);
        }
        catch
        {
            if (handle != IntPtr.Zero) NmGpuDestroy(handle);
            throw;
        }
    }
}

internal sealed record CpuReport(string Status, string Stage, string Hresult, bool HypervisorPresent,
    string HostVendor, string GuestVendor, bool GuestAvx, bool GuestAvx2, uint VmExits, uint IoExits,
    string Rax, string StoredValue, string Rip, string Serial, long ElapsedMs, bool MacOsBooted);
internal sealed record GpuReport(string Status, string Stage, string Hresult, string Adapter,
    uint VendorId, uint DeviceId, uint Frames, bool Hardware, bool CpuFallback, bool GuestGpuAccelerated);
