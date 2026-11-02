#!/usr/bin/env bash
# Invoked by local-usb-capture.sh as root on the Pi.
set -euo pipefail
umask 077

token=${1:?token required}
duration=${2:?duration required}
[[ $token =~ ^[0-9]+-[0-9]+$ && $duration =~ ^[0-9]+$ ]] || exit 2
deb="/tmp/aa2acp-usb-${token}.deb"
archive="/tmp/aa2acp-usb-${token}.tar.gz"
stage=$(mktemp -d /tmp/aa2acp-usb-stage.XXXXXX)
was_active=$(systemctl is-active aa2acp.service || true)
restore_unit="aa2acp-usb-restore-${token}"

restore() {
  result=$?
  trap - EXIT
  if [[ $was_active == active ]]; then
    if systemctl start aa2acp.service; then
      systemctl stop "${restore_unit}.timer" 2>/dev/null || true
    else
      result=1
    fi
  fi
  rm -rf -- "$stage"
  exit "$result"
}
trap restore EXIT

[[ $(uname -m) == aarch64 ]]
[[ $(dpkg-deb -f "$deb" Architecture) == arm64 ]]
mkdir -m 0700 "$stage/data"
chown aa2acp:aa2acp "$stage/data"
dpkg-deb -x "$deb" "$stage/package"
test -x "$stage/package/usr/bin/aa2acp-media-capture"
test -e "$stage/package/usr/lib/aa2acp/libaasdk.so"
chmod 0755 "$stage" "$stage/package" "$stage/package/usr" \
  "$stage/package/usr/bin" "$stage/package/usr/lib" \
  "$stage/package/usr/lib/aa2acp"

{
  printf 'source package: %s\n' "$(dpkg-deb -f "$deb" Version)"
  printf 'service before: %s\n' "$was_active"
  systemctl show aa2acp.service -p ActiveState -p SubState \
    -p FragmentPath -p ExecStart
  dpkg-query -W -f='installed: ${Package} ${Version} ${Architecture}\n' \
    aa2acp 2>&1 || true
  sha256sum /usr/bin/aa2acp
} > "$stage/data/state-before.txt"

if [[ $was_active == active ]]; then
  systemd-run --quiet --unit "$restore_unit" \
    --on-active="$((duration + 60))s" \
    /usr/bin/systemctl start aa2acp.service
  systemctl stop aa2acp.service
fi
if systemctl is-active --quiet aa2acp.service; then
  echo 'AA2ACP service did not stop; capture aborted' >&2
  exit 1
fi

echo "Diagnostic ready. Connect razr 50 by USB and start Google Maps navigation. Capture runs for ${duration} seconds."
set +e
(
  # Also bound files written by older diagnostic packages without internal caps.
  ulimit -f 65536 || exit 1
  timeout --signal=TERM --kill-after=10s "${duration}s" \
    runuser -u aa2acp -- env \
    LD_LIBRARY_PATH="$stage/package/usr/lib/aa2acp" \
    "$stage/package/usr/bin/aa2acp-media-capture" \
    "$stage/data/capture"
) > "$stage/data/receiver.log" 2>&1
capture_status=$?
set -e
printf 'capture exit status: %s\n' "$capture_status" > "$stage/data/result.txt"
for name in video.h264 guidance.s16le; do
  if [[ -f $stage/data/capture/$name ]]; then
    stat -c '%n %s bytes' "$stage/data/capture/$name" >> "$stage/data/result.txt"
  fi
done
tar -C "$stage/data" -czf "$archive" .
chmod 0600 "$archive"
chown "${SUDO_USER:?sudo user required}" "$archive"
echo "Capture archived: $archive"
