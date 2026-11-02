# Testing and diagnostics

## USB capture: Raspberry Pi and razr 50

Run these commands on the PC that can SSH to the Pi. The script extracts the
diagnostic package under `/tmp`; it does not install or replace AA2ACP. It
stops the service for the capture and restarts it afterward if it was active.

1. Disconnect the phone from the Pi. Leave the Pi reachable over Ethernet.
2. Check SSH and the current service state:

   ```bash
   bash scripts/local-usb-capture.sh --preflight rpi4-aa2acp.local
   ```

3. Start a 180-second capture (use `600` for ten minutes):

   ```bash
   bash scripts/local-usb-capture.sh \
     ~/Downloads/aa2acp-capture1-arm64.deb \
     rpi4-aa2acp.local 180
   ```

4. When the script prints `Diagnostic ready`, connect the unlocked phone
   directly to a Pi USB-A port with a data cable. Leave USB role selection at
   its default. Accept Android Auto prompts, start Maps navigation, and request
   an audible direction.
5. After the script finishes, confirm the service is active:

   ```bash
   ssh rpi4-aa2acp.local systemctl is-active aa2acp.service
   ```

The script prints the local results directory. It contains `result.txt`,
`receiver.log`, and the capture files. A timed-out capture normally returns
status 124. That only means the timer expired; check the file sizes to see
whether media arrived. If the script or SSH session fails, restore the service
manually:

```bash
ssh -t rpi4-aa2acp.local 'sudo systemctl start aa2acp.service'
```

Do not upload raw captures or logs without reviewing them. Video and audio may
contain map, route, phone, or device information.

## Decode captured media

Run on a PC with FFmpeg, from the results directory:

```bash
ffprobe -v error -count_frames \
  -show_entries stream=codec_name,width,height,nb_read_frames \
  -of default=nw=1 capture/video.h264
ffmpeg -i capture/video.h264 -frames:v 1 capture/frame.png
ffmpeg -f s16le -ar 16000 -ac 1 -i capture/guidance.s16le \
  capture/guidance.wav
```

Optional playback:

```bash
ffplay capture/video.h264
ffplay capture/guidance.wav
```

## Find the failing stage

| Evidence | Next area to investigate |
| --- | --- |
| New USB over-current, descriptor errors, or repeated kernel disconnects | Pi port, cable, hub/adapter, phone connector, power. Hold code changes. |
| No `AOAP transport ready` event | USB link and Android accessory negotiation |
| AOAP appears, but no stable control/TLS session or service discovery | AASDK handshake/authentication and sanitized receiver events |
| Video configured/started, but `video.h264` stays empty | Confirm Maps is projecting; then inspect media callback and video ACK path |
| Guidance prompt played, but `guidance.s16le` stays empty | Audio channel negotiation and receiver callback |
| Files contain data, but FFmpeg cannot decode | H.264 normalization or media framing |
| Media decodes, but CarPlay does not show/play it | AirPlay session, head-unit capability profile, output routing |

Error 10 (`USB_TRANSFER`, native 1) is a USB transfer failure; compare its
time with kernel disconnects. Error 25 is `SSL_WRITE`; native 2 means
`SSL_ERROR_WANT_READ`. Interpret it with surrounding session events, not alone.
Video-start events with zero bytes do not prove that frames were received.

For each run, record event order, video/audio byte counts, kernel USB error
counts, and decoder results. Redact phone IDs, USB addresses, Bluetooth and IP
addresses, route imagery, and audio before sharing.

## Cloud-driven capture

The diagnostic receiver and `aa2acp.service` cannot own the phone at the same
time. In the current Cloud setup, `tazaki` belongs to the `aa2acp` USB group.
To let Cloud capture directly:

1. Run `sudo systemctl stop aa2acp.service` on the Pi.
2. Tell Codex Cloud the phone is connected and ready. Cloud starts a timed
   capture; then connect the phone and start navigation when asked.
3. After analysis, run `sudo systemctl start aa2acp.service` on the Pi if you
   want normal AA2ACP operation again.

Do not start the service while Cloud capture is running.

## What the capture does not test

`aa2acp-media-capture` runs the wired Android Auto receiver without Bluetooth,
NetworkManager, or CarPlay. It advertises a fixed 1280x720 display and records
normalized H.264 plus 16 kHz mono guidance PCM. It is not a CarPlay emulator;
decoding these files does not prove compatibility with a MINI head unit.
Writes are bounded to 64 MiB for video and 16 MiB for guidance audio in the
current binary; the Pi runner also caps each output file at 64 MiB for older
packages.

Synthetic H.264/PCM checks validate local decoders only. They do not emulate an
Android phone or prove that AA2ACP receives media from one.

Current razr 50 runs reached AOAP, control discovery, video configuration, and
video-start events, but repeatedly disconnected before media arrived. Kernel
logs showed repeated disconnects on the same USB path; one later sample had no
over-current events. The physical USB path remains the first gate to pass.

## Other diagnostics

- Deb service logs: `journalctl -u aa2acp.service`.
- Log level: set `AA2ACP_LOG_LEVEL=debug` in a systemd drop-in, then restart
  the service. Keep debug logs private and redact before sharing.
- Optional raw H.264 capture: set `AA2ACP_DUMP_H264=/tmp/android-auto.h264`
  when launching the daemon. It is owner-only and capped at 64 MiB.
- Optional decrypted AirPlay event capture: set
  `AA2ACP_DUMP_CARPLAY_EVENTS=/tmp/carplay-events.bin` with debug logging. It
  is owner-only and capped at 8 MiB. Do not commit raw captures.

## Broader regression cases

- Fresh and existing Bluetooth pairings.
- Fresh and existing NetworkManager Wi-Fi profiles.
- Phone connect, unplug, replug, and daemon SIGTERM/SIGINT.
- Head-unit reconnect with pairing state retained.
- Cached and cold capability discovery.
- Synthetic decoder checks separately from phone and head-unit tests.
