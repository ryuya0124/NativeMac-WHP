using System.Text.Json;

namespace TahoeVm;

internal enum VmPowerState { Starting, Running, Restarting, Paused, Stopped, Faulted }

internal static class VmPowerProtocol
{
    internal static VmPowerState? Read(string line)
    {
        while (line.StartsWith("openvmm> ", StringComparison.Ordinal)) line = line[9..];
        const string prefix = "NATIVEMAC_POWER ";
        if (line.StartsWith(prefix, StringComparison.Ordinal))
        {
            try
            {
                using var json = JsonDocument.Parse(line[prefix.Length..]);
                if (json.RootElement.ValueKind != JsonValueKind.Object ||
                    !json.RootElement.TryGetProperty("state", out var state) || state.ValueKind != JsonValueKind.String)
                    return null;
                return state.GetString() switch
                {
                    "running" => VmPowerState.Running,
                    "restarting" => VmPowerState.Restarting,
                    "stopped" => VmPowerState.Stopped,
                    "faulted" => VmPowerState.Faulted,
                    _ => null
                };
            }
            catch (JsonException) { return null; }
        }
        // These acknowledgements follow successful VMM RPC completion. A sent
        // command, a static display or a disconnected SSH session is no proof.
        if (line.Contains(" INFO openvmm_entry::repl:  pause complete", StringComparison.Ordinal))
            return VmPowerState.Paused;
        if (line.Contains(" INFO openvmm_entry::repl:  resumed complete", StringComparison.Ordinal))
            return VmPowerState.Running;
        return null;
    }
}
