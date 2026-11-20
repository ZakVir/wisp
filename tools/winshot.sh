#!/bin/sh
# Screenshot every on-screen window owned by a process name (default Wisp) into tools/out/.
# Usage: tools/winshot.sh [OwnerName] [label]
OWNER="${1:-Wisp}"; LABEL="${2:-shot}"
cd "$(dirname "$0")/.."
mkdir -p tools/out
IDS=$(swift -e "
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == \"$OWNER\" && (w[kCGWindowLayer as String] as? Int ?? 0) < 1000 {
  let b = w[kCGWindowBounds as String] as! [String: Any]
  if (b[\"Width\"] as! Double) > 60 { print(w[kCGWindowNumber as String]!) }
}" 2>/dev/null)
i=0
for id in $IDS; do
  screencapture -x -o -l"$id" "tools/out/${LABEL}_$i.png" && echo "tools/out/${LABEL}_$i.png"
  i=$((i+1))
done
