using TahoeVm;

var cases = new (string Line, VmPowerState? Expected)[]
{
    ("NATIVEMAC_POWER {\"state\":\"running\",\"exitCode\":0}", VmPowerState.Running),
    ("NATIVEMAC_POWER {\"state\":\"restarting\",\"exitCode\":75}", VmPowerState.Restarting),
    ("openvmm> NATIVEMAC_POWER {\"state\":\"restarting\",\"exitCode\":75}", VmPowerState.Restarting),
    ("openvmm> openvmm> NATIVEMAC_POWER {\"state\":\"stopped\",\"exitCode\":0}", VmPowerState.Stopped),
    ("NATIVEMAC_POWER {\"state\":\"stopped\",\"exitCode\":0}", VmPowerState.Stopped),
    ("NATIVEMAC_POWER {\"state\":\"faulted\",\"exitCode\":70}", VmPowerState.Faulted),
    ("  42.000s  INFO openvmm_entry::repl:  pause complete", VmPowerState.Paused),
    ("  44.000s  INFO openvmm_entry::repl:  resumed complete", VmPowerState.Running),
    ("  45.000s  INFO openvmm_entry::repl:  guest halted reason=\"PowerOff\"", null),
    ("pause", null),
    ("resume", null),
    ("error: failed to resume complete", null),
    ("NATIVEMAC_POWER invalid", null),
    ("NATIVEMAC_POWER []", null),
    ("NATIVEMAC_POWER {\"state\":1}", null),
    ("NATIVEMAC_POWER {\"state\":\"unknown\"}", null),
    ("NATIVEMAC_POWER {}", null)
};
foreach (var (line, expected) in cases)
{
    var actual = VmPowerProtocol.Read(line);
    if (actual != expected) throw new Exception($"Expected {expected}, got {actual}: {line}");
}
Console.WriteLine($"PASS: {cases.Length} power events, acknowledgement recognition and malformed input cases.");
