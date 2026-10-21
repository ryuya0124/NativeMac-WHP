#!/bin/bash
# Run once from this x86-64 VM's Recovery Terminal after OS installation.
set -euo pipefail
test "$(uname -m)" = x86_64
: "${NM_URL:?Set NM_URL to the temporary lab channel}"
data="${1:-/Volumes/NativeMac - Data}"
case "$data" in /Volumes/*) ;; *) exit 1 ;; esac
test -d "$data/Library"
mkdir -p "$data/usr/local/bin" "$data/usr/local/libexec" "$data/Library/LaunchDaemons"
curl -fsS "${NM_URL}metal-probe-x64" -o "$data/usr/local/bin/metal-probe-x64"
chmod 755 "$data/usr/local/bin/metal-probe-x64"

cat > "$data/usr/local/libexec/nativemac-gpu-check" <<'SCRIPT'
#!/bin/bash
set -u
report=/var/tmp/nativemac-metal.json
for attempt in {1..45}; do
    /usr/local/bin/metal-probe-x64 > "$report" 2>/var/tmp/nativemac-metal-error.log
    status=$?
    if test "$status" = 0; then break; fi
    sleep 2
done
{
    echo NATIVEMAC_GUEST_METAL_RESULT
    date
    uname -a
    sw_vers
    cat "$report"
    cat /var/tmp/nativemac-metal-error.log
    ioreg -r -c IOGPU -l
    system_profiler SPDisplaysDataType
} > /var/tmp/nativemac-gpu-report.txt 2>&1
for attempt in {1..30}; do
    if curl -fsS --connect-timeout 3 --max-time 10 --data-binary @/var/tmp/nativemac-gpu-report.txt "${NM_URL}result"; then
        if test "$status" = 0; then
            rm -f /Library/LaunchDaemons/com.nativemac.gpu-check.plist
        fi
        exit "$status"
    fi
    sleep 2
done
exit 1
SCRIPT
chmod 755 "$data/usr/local/libexec/nativemac-gpu-check"
cat > "$data/Library/LaunchDaemons/com.nativemac.gpu-check.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.nativemac.gpu-check</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/usr/local/libexec/nativemac-gpu-check</string></array>
<key>RunAtLoad</key><true/>
<key>EnvironmentVariables</key><dict><key>NM_URL</key><string>${NM_URL}</string></dict>
<key>StandardOutPath</key><string>/var/log/nativemac-gpu.log</string>
<key>StandardErrorPath</key><string>/var/log/nativemac-gpu.log</string>
</dict></plist>
PLIST
chmod 644 "$data/Library/LaunchDaemons/com.nativemac.gpu-check.plist"
chown 0:0 "$data/Library/LaunchDaemons/com.nativemac.gpu-check.plist"
echo 'One-time Metal check installed on the guest Data volume.'
