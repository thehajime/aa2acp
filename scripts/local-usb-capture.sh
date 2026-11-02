#!/usr/bin/env bash
# Run on a local PC with SSH access to the Pi, after downloading the arm64 deb.
set -euo pipefail
umask 077

if [[ ${1:-} == --preflight ]]; then
  host=${2:-rpi4-aa2acp.local}
  ssh -F /dev/null -o ConnectTimeout=8 "$host" \
    'printf "architecture: "; uname -m; printf "service: "; systemctl is-active aa2acp.service; printf "binary: "; sha256sum /usr/bin/aa2acp; printf "Ethernet: "; cat /sys/class/net/eth0/operstate'
  exit
fi

deb=${1:?usage: local-usb-capture.sh ARM64_DEB [SSH_HOST] [SECONDS]}
host=${2:-rpi4-aa2acp.local}
duration=${3:-180}
[[ -f $deb && $duration =~ ^[0-9]+$ ]] || exit 2
(( duration >= 30 && duration <= 900 )) || exit 2
token="$(date +%s)-$$"
remote_base="/tmp/aa2acp-usb-${token}"
local_dir="aa2acp-usb-${token}"
mkdir -m 0700 "$local_dir"

ssh -F /dev/null -o ConnectTimeout=8 "$host" \
  'command -v sudo dpkg-deb runuser timeout tar systemd-run >/dev/null; test "$(systemctl is-active aa2acp.service)" = active'
scp -F /dev/null -- "$deb" "$host:${remote_base}.deb"
scp -F /dev/null -- "$(dirname "$0")/pi-usb-capture-remote.sh" \
  "$host:${remote_base}.sh"

echo 'Pi will stop aa2acp.service for the timed capture and restart it afterward.'
result=0
if ! ssh -F /dev/null -tt "$host" \
  "sudo bash '${remote_base}.sh' '$token' '$duration'"; then
  echo 'Capture command failed; checking service and retrieving any available archive.' >&2
  result=1
fi
if scp -F /dev/null -- "$host:${remote_base}.tar.gz" "$local_dir/capture.tar.gz"; then
  if ! tar -C "$local_dir" -xzf "$local_dir/capture.tar.gz"; then
    result=1
  fi
  ssh -F /dev/null "$host" \
    "rm -f '${remote_base}.deb' '${remote_base}.sh' '${remote_base}.tar.gz'" || result=1
else
  echo "Archive remains on the Pi if it was created: ${remote_base}.tar.gz" >&2
  result=1
fi
if ! ssh -F /dev/null "$host" 'systemctl is-active --quiet aa2acp.service'; then
  echo 'AA2ACP service is not confirmed active; inspect it over Ethernet SSH.' >&2
  result=1
fi
echo "Local results: $local_dir"
exit "$result"
