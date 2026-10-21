/* OpenVMM MSVM firmware declares VMBS inside If (VCFG > 0).
 * Defer its override until that conditional declaration has executed.
 * The upstream SSDT's unconditional Scope fails on Tahoe's ACPICA.
 */
DefinitionBlock ("", "SSDT", 2, "NMAC", "NMVMBUS", 1)
{
    External (\_SB.VMOD, DeviceObj)
    External (\_SB.VMOD.VMBS, DeviceObj)
    External (VCFG, FieldUnitObj)
    Scope (\_SB.VMOD)
    {
        Name (_HID, EisaId ("VMD0001"))
    }
    If (VCFG > Zero)
    {
        Scope (\_SB.VMOD.VMBS)
        {
            Name (_HID, EisaId ("VBS0001"))
        }
    }
}
