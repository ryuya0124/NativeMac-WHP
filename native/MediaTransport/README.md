# Direct media channel

`transport.py` connects the development guest directly to a fixed Windows
interface over pinned TLS. Video and audio payloads never use SSH. SSH may
deploy source, private configuration and authored maintenance fixtures; it is
not a media fallback. This CPU/TCP path is not shared GPU memory.

On Windows, create private material under ignored `artifacts/`:

```powershell
scripts/Prepare-DirectMedia.ps1 -HostAddress <Windows-interface-IPv4>
```

This needs installed OpenSSL (Git for Windows' copy is also located). It creates
a dedicated one-year certificate/private key, a random 256-bit client secret,
`host.json` and `guest.json`, protected by a current-user-only Windows ACL.
Existing output directories are refused. Private keys and configuration must
never be committed, printed or copied to a public report.

Copy only `transport.py`, `install_guest.sh`, `guest.json` and
`host-certificate.pem` into an owned guest staging directory, then run
`sudo bash install_guest.sh` there. Deployment is maintenance. The qualified
installer accepts x86-64 Darwin 25.6 and installs root-owned support files;
`guest.json` is mode 0600. LaunchDaemon `io.nativemac.media.transport` starts
the guest endpoint at boot. The host wrapper uses `host.json` as documented in
[`../VideoBridge`](../VideoBridge/README.md).

The guest validates certificate expiry, the fixed service hostname, a dedicated
CA set, the exact certificate SHA-256 pin and ALPN before sending credentials.
The host requires the separate client secret. No system trust store is changed.
One explicit Windows interface listens on port 54887; only authenticated `V`
and `A` channels reach fixed host loopback codec/audio ports 54883/54884.
Guest consumers reach loopback 54885/54886. Firewall policy must permit the
chosen host interface; the setup does not alter the firewall.

Each TLS connection has one I/O thread for both directions, queues of at most
256 KiB per direction, five-second authentication, 300-second idle and one-hour
lifetime limits. There are at most six connections. EOF drains queued bytes.
Logs contain connection byte counts/status, never media or secrets.

Qualification with the running host service:

```powershell
python native/MediaTransport/verify_transport.py --host-config artifacts/direct-media/host.json
```

This checks wrong pin/secret/CA rejection and correct authentication, plus a
local authored duplex/EOF fixture. The local fixture does not measure VM link
throughput. Source/aggregate evidence is in
`../../docs/verification/video-direct-gpu-sharing.json`.

To disable, run `sudo bash disable_guest.sh` in the guest and stop the owned
host wrapper (or VM launcher). The disable script removes its own launch job;
it starts no replacement. To rotate an expiring certificate or secret, prepare
a fresh ignored directory, stop the owned service, deploy the new guest
configuration/certificate and update the host configuration together.
