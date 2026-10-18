#!/bin/sh
# Add .deb files to the apt repository in DIR, rebuild its index and sign it.
#
#   debian/publish-apt.sh DIR PACKAGE.deb...
#
# DIR is the checked-out gh-pages branch (it may be empty the first time).
# Needs apt-ftparchive (apt-utils) and gpg with the secret signing key.
# APT_SIGNING_KEY_ID picks the key (default: the first secret key);
# APT_SIGNING_PASSPHRASE unlocks it if it has one.
set -eu

SUITE=stable
COMPONENT=main
ARCHES="all amd64 arm64 armhf i386"  # packages are "all"; the others are empty, so apt doesn't warn
KEEP=5                               # versions kept per package, for downgrades
URL=${APT_REPO_URL:-https://linuxrrze.github.io/slim-scan/}

die() { echo "error: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: $0 DIR PACKAGE.deb..."
DIR=$1; shift
[ -d "$DIR" ] || die "$DIR is not a directory"
for deb in "$@"; do
	case $deb in *.deb) ;; *) die "not a .deb: $deb" ;; esac
	[ -f "$deb" ] || die "$deb not found"
done
command -v apt-ftparchive >/dev/null 2>&1 || die "apt-ftparchive not found (apt install apt-utils)"

KEY=${APT_SIGNING_KEY_ID:-$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')}
[ -n "$KEY" ] || die "no secret gpg key for signing"

sign() {  # sign OUT ARGS...: gpg with the repository key, the passphrase on stdin
	out=$1; shift
	if [ -n "${APT_SIGNING_PASSPHRASE:-}" ]; then
		printf '%s' "$APT_SIGNING_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
			--passphrase-fd 0 --local-user "$KEY" --output "$out" "$@"
	else
		gpg --batch --yes --local-user "$KEY" --output "$out" "$@"
	fi
}

POOL=pool/$COMPONENT/s/slim-scan
mkdir -p "$DIR/$POOL"
cp "$@" "$DIR/$POOL/"

# Keep the newest versions of each package.
for name in $(ls "$DIR/$POOL" | sed -n 's/_.*\.deb$//p' | sort -u); do
	ls "$DIR/$POOL" | grep "^${name}_.*\.deb$" | sort -V -r | tail -n +$((KEEP + 1)) |
		while read -r old; do rm -f "$DIR/$POOL/$old"; echo "removed $old"; done
done

cd "$DIR"
rm -rf "dists/$SUITE"
for arch in $ARCHES; do
	mkdir -p "dists/$SUITE/$COMPONENT/binary-$arch"
	if [ "$arch" = all ]; then
		apt-ftparchive packages pool > "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
	else
		: > "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
	fi
	gzip -9n -k "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
	xz -k "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
done
apt-ftparchive \
	-o APT::FTPArchive::Release::Origin="Slim Scan" \
	-o APT::FTPArchive::Release::Label="Slim Scan" \
	-o APT::FTPArchive::Release::Suite="$SUITE" \
	-o APT::FTPArchive::Release::Codename="$SUITE" \
	-o APT::FTPArchive::Release::Architectures="$ARCHES" \
	-o APT::FTPArchive::Release::Components="$COMPONENT" \
	-o APT::FTPArchive::Release::Description="Slim Scan packages for Debian and Ubuntu" \
	release "dists/$SUITE" > Release.tmp
mv Release.tmp "dists/$SUITE/Release"
sign "dists/$SUITE/InRelease" --clearsign "dists/$SUITE/Release"
sign "dists/$SUITE/Release.gpg" --armor --detach-sign "dists/$SUITE/Release"

gpg --batch --yes --output slim-scan-archive-keyring.gpg --export "$KEY"
gpg --batch --yes --armor --output slim-scan-archive-keyring.asc --export "$KEY"
cat > slim-scan.sources <<END
Types: deb
URIs: $URL
Suites: $SUITE
Components: $COMPONENT
Signed-By: /usr/share/keyrings/slim-scan-archive-keyring.gpg
END
touch .nojekyll  # serve the files as they are
cat > index.html <<END
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Slim Scan apt repository</title>
<style>body { font: 16px/1.5 sans-serif; max-width: 46em; margin: 2em auto; padding: 0 16px; }
pre { background: #eee; padding: 1em; overflow-x: auto; }</style></head>
<body>
<h1>Slim Scan apt repository</h1>
<p>Packages of <a href="https://github.com/linuxrrze/slim-scan">Slim Scan</a> for Ubuntu 24.04+ and Debian 13+.</p>
<pre>sudo curl -fsSLo /usr/share/keyrings/slim-scan-archive-keyring.gpg \\
  ${URL}slim-scan-archive-keyring.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/slim-scan.sources \\
  ${URL}slim-scan.sources
sudo apt update
sudo apt install slim-scan-gui   # the app; or just slim-scan for the command</pre>
<p>Signing key: <a href="slim-scan-archive-keyring.asc">slim-scan-archive-keyring.asc</a>, fingerprint <code>$KEY</code>.</p>
</body>
</html>
END
echo "Repository in $DIR updated: $(ls "$POOL" | tr '\n' ' ')"
