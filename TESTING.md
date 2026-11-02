# Runbook and diagnostics

How to verify an AA2ACP setup end to end, and what to reach for when it
misbehaves. Installation is covered in the [README](README.md); this document
assumes a running daemon (deb service or a locally built binary).

## Verified state

Real-head-unit testing has verified the wireless connection bootstrap:

1. AA2ACP pairs with the configured head unit over Bluetooth.
2. It completes iAP2/CSM and MFi authentication.
3. It joins the head unit's CarPlay Wi-Fi network.
4. It completes encrypted AirPlay pairing, verification, and initial session
   setup.

Screen-stream setup and Android Auto H.264 forwarding remain under active
compatibility testing. Audio, microphone, and input/control forwarding are
implemented but not yet verified end to end; call-audio interoperability
remains incomplete. The active work is in [TODO.md](TODO.md).

Synthetic H.264 and PCM checks establish that the local media tools can decode
the chosen test formats. They do not establish that an Android phone sends those
formats, that AA2ACP captures or forwards them correctly, or that a CarPlay head
unit renders or plays them. Record phone capture, bridge forwarding, and head-unit
output as separate milestones when testing on hardware. Wireless Android Auto
has no verified milestones yet; the current receiver uses USB.

## Runbook

Open the management UI (see the README), scan if necessary, select the CarPlay
head unit's Bluetooth address, select the Wi-Fi interface that should join its
CarPlay network, and save. The selected device is pinned through the persistent
AirPlay pairing record; a later connection validates that same head unit. The
daemon does not start its Android Auto USB receiver until both settings are
saved; if a phone was already connected, unplug and reconnect it after setup.

Then plug in the Android phone. The normal successful sequence includes:

```text
Android Auto video stream started
 preparing CarPlay for Android Auto
CarPlay session started
... link established (NORMAL)
... Wi-Fi: joining SSID ...
... AirPlay: encrypted RECORD accepted
... forwarded Android Auto H.264 config and cached keyframe
```

CarPlay runs in a persistent worker process created before the daemon starts
its threads. The daemon sends start and stop commands over a local control
socket; Android Auto media continues to use its dedicated Unix sockets.

If the first AirPlay connection after Wi-Fi handover fails, the bridge waits
one second and retries the AirPlay phase once without repeating Bluetooth
pairing or the Wi-Fi handover.

## Diagnostics

- **Logs first.** Configuration, the AirPlay pairing identity, and up to 30
  launch-rotated logs live in `$XDG_STATE_HOME/aa2acp` (`/var/lib/aa2acp` for
  the deb install, `~/.local/state/aa2acp` when running as your own user).
  Inspect `logs/` when a failed session is no longer visible in the terminal.
- `bluetoothctl` inspects or removes a stale BlueZ bond. AA2ACP reuses an
  existing valid bond and otherwise performs Just Works pairing.
- The management UI's Bluetooth scan covers Bluetooth Classic (BR/EDR), which
  is the transport used for CarPlay pairing and SDP; some head units take time
  to become visible.
- Set `AA2ACP_DUMP_H264=/tmp/android-auto.h264` before launching the daemon to
  capture the raw Android Auto H.264 elementary stream. The opt-in capture is
  owner-only and capped at 64 MiB; treat it as sensitive and sanitize before
  sharing.
- Set `AA2ACP_DUMP_CARPLAY_EVENTS=/tmp/carplay-events.bin` with debug logging
  to retain length-prefixed decrypted AirPlay event messages for private
  analysis. The opt-in capture refuses symlinks, is owner-only, and capped at
  8 MiB. Do not commit raw captures; sanitize any resulting fixture first.
- The bridge caches CarPlay's head-unit capabilities (main display, supported
  direct-PCM audio routes) in `$XDG_STATE_HOME/aa2acp/head-unit-capabilities`
  and uses a supported cached resolution for Android Auto. A first connection,
  unavailable cache, or unsupported profile waits up to 30 seconds for CarPlay
  discovery before falling back to 1280x720.
- `journalctl -u aa2acp.service` for the deb-installed service; run the binary
  in a terminal without `--no-file-log` for file logging during local runs.
- **Log level** defaults to `info` and can be raised to `debug` via the
  `AA2ACP_LOG_LEVEL` environment variable (`debug`, `info`, `warning`,
  `error`). For the deb-installed service, use a systemd drop-in:

  ```bash
  sudo systemctl edit aa2acp.service
  # add:
  #   [Service]
  #   Environment=AA2ACP_LOG_LEVEL=debug
  sudo systemctl restart aa2acp.service
  ```

## Car-free Android Auto media capture

`aa2acp-media-capture` runs the existing USB Android Auto receiver without
starting Bluetooth, NetworkManager, or CarPlay. It advertises a fixed 1280x720
display, 48 kHz stereo media audio, and 16 kHz mono guidance/system audio. It
writes normalized H.264 and guidance PCM to a new owner-only directory. This
is an **internal media tap**, not a CarPlay/AirPlay protocol emulator, and
successful decoding does not establish compatibility with a MINI head unit.
The capture stops with an error if video exceeds 64 MiB, guidance audio exceeds
16 MiB, or a write fails; inspect `result.txt` before interpreting the files.
The Pi runner also limits each output file to 64 MiB for older diagnostic
packages that lack those internal limits.

Run it only after recording the current service state and arranging a rollback:
the installed daemon and this diagnostic cannot own the same USB phone at once.
The capture files can contain private map and route data; do not upload them
without reviewing and sanitizing them. No phone is needed for the offline
decoder check below.

```bash
# On a development host with FFmpeg, after a capture has been transferred
# privately from the Pi:
ffprobe -v error -count_frames \
  -show_entries stream=codec_name,width,height,nb_read_frames \
  -of default=nw=1 capture/video.h264
ffmpeg -i capture/video.h264 -frames:v 1 capture/frame.png
ffmpeg -f s16le -ar 16000 -ac 1 -i capture/guidance.s16le \
  capture/guidance.wav
ffplay capture/video.h264
ffplay capture/guidance.wav
```

Record these separately: USB/AOAP ready, Android Auto control/TLS ready,
video frame received, H.264 decoded, image displayed, guidance PCM received,
PCM converted, and audio heard. Empty files mean only that no corresponding
payload was captured; they do not prove a receiver defect. The diagnostic
prints receiver events and exits on SIGINT/SIGTERM. Its output directory must
not already exist.

### Local Pi and razr 50 runbook

Use a PC on the Pi's Ethernet management network. Download the reviewed
`aa2acp-0.1.11~g078fee9+capture1-Linux.deb` artifact to that PC and keep it
private. The script copies it to the Pi and **extracts it without installing
it**. The script requires SSH, `sudo` access on the Pi, and standard runtime
utilities (`dpkg-deb`, `runuser`, `timeout`, `tar`, `systemd-run`). It does not
install a compiler or alter Bluetooth/Wi-Fi settings. Run from a terminal so
`sudo` can ask for a password.

Before connecting the phone, run the read-only preflight. Pass the Pi's
Ethernet IP instead of its `.local` name if that is more reliable on the PC.

```bash
./scripts/local-usb-capture.sh --preflight rpi4-aa2acp.local
```

```bash
./scripts/local-usb-capture.sh \
  ~/Downloads/aa2acp-0.1.11~g078fee9+capture1-Linux.deb \
  rpi4-aa2acp.local 180
```

Before starting, ensure the PC reaches the Pi by Ethernet, keep the phone
unplugged, and leave the original service active. The remote script records
the service state, installed package query and original executable hash. It
then schedules a systemd fallback restart, stops `aa2acp.service`, and runs
the extracted diagnostic as the existing `aa2acp` user. When it prints
`Diagnostic ready`, connect the razr 50 with a data-capable USB cable. Accept
Android Auto prompts on the phone. Open Google Maps, select a safe route, and
start navigation with an audible guidance prompt during the capture interval.
The script runs for 30 to 900 seconds (180 by default). On exit it restarts
the original service and retrieves an owner-only archive to the local PC. If
SSH is interrupted, a transient systemd timer attempts to restart the service
after the capture interval plus 60 seconds. If the local retrieval fails,
the private archive remains on the Pi at the path printed by the remote
script. The local script checks that the original service is active even if
capture or retrieval fails. Do not share raw captures or `receiver.log`
publicly.

The local output directory contains `state-before.txt`, `result.txt`,
`receiver.log`, and `capture/video.h264` and `capture/guidance.s16le` when
available. The event types are: 1 = AOAP USB transport, 2 = Android Auto
control/TLS, 3 = video configured, 4 = video started, 5 = teardown, 6 =
disconnected, 7 = error; 0 means waiting. File sizes greater than zero show
payload reception, not successful decoding or audible playback. Run the
`ffprobe`, `ffmpeg`, and `ffplay` commands above on the local PC to check those
later stages. Record the result of each stage separately. When sharing a
diagnostic summary, report event type numbers and file sizes, and remove
phone identifiers, addresses, route images, and audio from the shared copy.

Rollback is `sudo systemctl start aa2acp.service` on the Pi; the script and
fallback timer perform it automatically if the service was initially active.
Verify with `systemctl is-active aa2acp.service`. The extracted diagnostic
never overwrites `/usr/bin/aa2acp`, `/var/lib/aa2acp`, package metadata,
pairing state, or saved NetworkManager profiles.

For an offline decoder smoke check, generate a two-second H.264 color card and
16 kHz mono PCM tone with FFmpeg's `color` and `sine` filters, then apply the
`ffprobe` and `ffmpeg` commands above. This checks the decoder workflow only.

## Regression cases

Before considering a transport or lifecycle change complete, test:

- fresh Bluetooth pairing and an already-paired head unit;
- a fresh NetworkManager connection and an existing saved Wi-Fi profile;
- phone connect, unplug, replug, and daemon `SIGTERM`/`SIGINT`;
- head-unit reconnect with the previous AirPlay pairing record retained;
- cached vs cold head-unit capability negotiation.
