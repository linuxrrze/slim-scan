#!/bin/sh
# Write debian/changelog for the version in gui/scanform.py. The release
# notes live in the AppStream metainfo, so the changelog only points there.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$ROOT/gui/scanform.py")
[ -n "$VERSION" ] || { echo "error: no VERSION in gui/scanform.py" >&2; exit 1; }
MAINTAINER=$(sed -n 's/^Maintainer: //p' "$ROOT/debian/control")
# The commit date, so the same commit always builds the same package.
DATE=$(git -C "$ROOT" log -1 --format=%aD 2>/dev/null || date -R)
cat > "$ROOT/debian/changelog" <<END
slim-scan ($VERSION) unstable; urgency=medium

  * Release $VERSION. See the release notes in
    /usr/share/metainfo/io.github.linuxrrze.SlimScan.metainfo.xml.

 -- $MAINTAINER  $DATE
END
echo "debian/changelog: $VERSION"
