#!/bin/sh
# Capture Wisp's overlay window ONLY (transparent; no other screen content) as a frame sequence while the
# debug demo script runs. Usage: tools/overlay_frames.sh [frames=40] [target=900,500]
cd "$(dirname "$0")/.."
N="${1:-40}"; TARGET="${2:-900,500}"
pkill -x Wisp; sleep 0.5
WISP_DEMO_SCRIPT=${WISP_DEMO:-1} WISP_DEMO_TARGET="$TARGET" build/DerivedData/Build/Products/Debug/Wisp.app/Contents/MacOS/Wisp >/dev/null 2>&1 &
sleep 1.2
ID=$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Wisp" {
  let b = w[kCGWindowBounds as String] as! [String: Any]
  if (b["Width"] as! Double) > 1000 { print(w[kCGWindowNumber as String]!); break }
}' 2>/dev/null)
rm -rf tools/out/ovl && mkdir -p tools/out/ovl
i=0
while [ $i -lt "$N" ]; do
  screencapture -x -o -l"$ID" "tools/out/ovl/f_$(printf %03d $i).png"
  i=$((i+1))
done
pkill -x Wisp
echo "captured $N frames of window $ID"
