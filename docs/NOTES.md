# Development notes

Findings and open points for later work. What the tool does today is in [README.md](../README.md) and [gui/README.md](../gui/README.md); this file keeps what is not obvious from the code.

## The ES-580W's own cropping through SANE (epsonds)

Without fixes, `epsonds` returns every ADF page at the full feeder travel (2544 × 4642 px at 300 dpi, 8.5 × 15.5 in). The scanner can crop to the sheet (capabilities `ADFCRP`, `ADFSKEW`, `ADFPEDT`; area 850 × 1550 at 100 dpi, center aligned), but two backend bugs keep that from working with `scanimage`:

1. **The crop option is reset.** `setvalue()` sets `OPT_ADF_CRP` to 0 whenever a geometry option is set, and `scanimage` always sets `br-x`/`br-y` last. So `#ADF…CRP` is never sent. Fixed by [MR !919](https://gitlab.com/sane-project/backends/-/merge_requests/919), which also sends `PEDT` (paper end detection) with `CRP`. Not merged or released as of October 2026.
2. **The ring buffer is too small for a larger page.** `sane_start()` sizes the front and back ring buffers from `s->params` (`bytes_per_line * lines`, epsonds.c around line 3345/3350 in 1.4.0). With cropping on, that is still the previous page's size. A page larger than the one before it overflows: `eds_ring_write: ring buffer full` in the debug log, then `Application transferred too few scanlines` from `scanimage`, and the next sheet jams in the feeder. The fix below grows the ring in `eds_decode_jpeg()` (backend/epsonds-jpeg.c), where the page's real size is known and the ring is still empty. `eds_ring_init()` reallocs, so it doesn't leak. The file is unchanged between 1.4.0 and master (October 2026), so the patch applies to both. It was proposed in the discussion of MR !919.

```diff
--- a/backend/epsonds-jpeg.c
+++ b/backend/epsonds-jpeg.c
@@ -143,6 +143,17 @@
 
 		int monoBufSize = (jpeg_cinfo.output_width + 7)/8;
 
+		/* With adf-crp every page has its own size; the ring was sized from
+		 * the previous page's parameters. It is still empty here: make room
+		 * for this page. */
+		SANE_Int needed = (needToConvertBW ? monoBufSize : bufSize) * (SANE_Int)jpeg_cinfo.output_height;
+		if (ringBuffer->fill == 0 && ringBuffer->size < needed) {
+			DBG(10, "%s: ring buffer grown from %d to %d bytes\n", __func__, ringBuffer->size, needed);
+			if (eds_ring_init(ringBuffer, needed) != SANE_STATUS_GOOD) {
+				DBG(1, "%s: out of memory for the ring buffer\n", __func__);
+			}
+		}
+
         JSAMPARRAY scanlines = (jpeg_cinfo.mem->alloc_sarray)((j_common_ptr)&jpeg_cinfo, JPOOL_IMAGE, bufSize, 1);
```

With both fixes (October 2026, ES-580W, ADF Duplex, color, 300 dpi), an A6 card followed by an A4 sheet came back as 1750 × 1241 and 2486 × 3527 px, front and back. A Debian/Ubuntu sane-backends package rebuilt with both patches works the same.

This tool needs no change for either case. `sane_switches_kept()` probes at connect time whether the crop option survives, and pages the scanner cut are analyzed with paper "scanner" and not cut again. `--info` shows which corrections the backend really applies.

Open:
- The raw (non-JPEG) path in `sane_read()` (around line 3451) sizes the ring the same way. Whether it has the same problem is unchecked.
- Follow MR !919: whether the ring fix is folded in or needs its own MR.
- Once a release contains both fixes, shorten README.md's "epsonds with the scanner's own cropping" and drop the rebuild instructions.
- There is no separate upstream issue for the crop bug. [Issue 792](https://gitlab.com/sane-project/backends/-/work_items/792) (ES-400 with epsonds) is related.

## Testing against a real scanner without system SANE

Testing without root, on a machine with no SANE installed:

- Unpack the distribution's `libsane1`, `libsane-common`, `sane-utils` and `sane-airscan` packages with `dpkg-deb -x` into a private directory.
- Set `LD_LIBRARY_PATH` to the unpacked `usr/lib/x86_64-linux-gnu` and its `sane/` subdirectory, `SANE_CONFIG_DIR` to a config directory whose `epsonds.conf` holds `net <scanner IP>`, and `PATH` to the unpacked `usr/bin` for `scanimage`.
- To test a patched backend, build only `epsonds` from the sane-backends release tarball. Run `./configure BACKENDS=epsonds --without-usb --without-avahi` (with `CPPFLAGS`/`LDFLAGS` pointing to libjpeg headers if they're missing), then `make -C lib; make -C sanei; make -C backend libsane-epsonds.la`. Put `backend/.libs/` first in `LD_LIBRARY_PATH`.
- `SANE_DEBUG_EPSONDS=20` logs to `scanimage`'s stderr, which this tool captures. Tee it to a file explicitly, or the log is lost.
- If `scanimage` stops in the middle of a batch, the scanner holds the sheet in the feeder, which looks like a paper jam.

## Debian packages and the apt repository

`.github/workflows/deb.yml` builds `slim-scan` and `slim-scan-gui` (both `Architecture: all`) from `debian/` on every push and pull request. It runs the tests, lintian, and an install and remove test on Debian 13, Ubuntu 24.04 and Ubuntu 26.04. The .debs are kept as the `debs` artifact.

Release: bump `VERSION` in `gui/scanform.py` and add the `<release>` to the metainfo, commit, then push the tag `vX.Y.Z`. The build fails if the tag, `VERSION` and the newest metainfo release differ. A tag also creates the GitHub Release with the .debs. Then `debian/publish-apt.sh` adds them to the apt repository on the `gh-pages` branch, keeps the last 5 versions of each package, and signs `Release`.

- `debian/changelog` isn't in git. `debian/gen-changelog.sh` writes it from `VERSION`, with the commit date, so the version lives in one place. Build locally with `debian/gen-changelog.sh && dpkg-buildpackage -us -uc -b`.
- The repository has one suite, `stable`, for all distributions. The dependencies (GTK 4.12+, libadwaita 1.5+) decide where it installs. On Debian 12, apt refuses `slim-scan-gui` because its GTK 4.8 is too old; `slim-scan` works there.
- Packages are listed only in `binary-all`. The `amd64`, `arm64`, `armhf` and `i386` lists are empty, so apt on those systems doesn't warn about a missing architecture.
- Lintian warns `no-manual-page` for both commands. There are no man pages yet.

One-time setup on GitHub:

1. Create a signing key, without a passphrase or with one stored as the secret `APT_SIGNING_PASSPHRASE`: `gpg --quick-gen-key "Slim Scan apt repository <…>" ed25519 sign 5y`. Store `gpg --armor --export-secret-keys <fingerprint>` as the repository secret `APT_SIGNING_KEY`. Keep a backup offline: with a new key, every user has to download the keyring again.
2. After the first tag has created the `gh-pages` branch: Settings → Pages → Deploy from a branch → `gh-pages`, `/ (root)`.
3. The key expires. Before that, extend it (`gpg --quick-set-expire`), update the secret and publish again. apt checks against the keyring file users downloaded, so they have to run the first `curl` command again; otherwise `apt update` fails once the old date has passed.

Leftover from the rename: `gui/install.sh --dist` still names its archive `scan-to-pdf-<version>.tar.gz`.

## libadwaita 1.5: close() right after present() is ignored

In libadwaita 1.5 (Ubuntu 24.04 has 1.5.0), `AdwDialog.close()` does nothing during the first two frames after `present()`. The dialog opens anyway and `closed` is not emitted. Upstream fixed this in 1.7 (commit 9bc2b372, "dialog: Handle close() before and right after present()"); the 1.5 branch has no backport.

Users can't close a dialog that fast, so the app is not affected. The GTK tests did it on every dialog, so on 1.5 the preferences were never saved and 7 tests timed out. They now open dialogs with `present()` from `gui/tests/test_gui_gtk.py`, which waits three frames. To test against 1.5 elsewhere, put the `libadwaita-1-0` and `gir1.2-adw-1` packages from Ubuntu 24.04 in front of a newer GTK on `LD_LIBRARY_PATH` and `GI_TYPELIB_PATH`.

## Open ideas

None of these are decided:

- **`--crop sides` leaves a strip of backing:** about 15 mm of feeder backing can remain below the sheet. Should "sides" also cut that bottom strip?
- **Center alignment:** `epsonds` reports the ADF as center aligned. A fixed paper size with a left offset of 0 may sit off-center through SANE. Check on paper.
- **German screenshots:** with `SCREENSHOT_LANGUAGE=de`, `gui/tools/screenshots.py` shows the app's own texts in German. Texts from GTK and libadwaita themselves stay English when the system lacks the `de_DE` locale.
- **Detection constants:** the paper-detection constants in slim_scan.py (`PAPER_MIN_CONTRAST`, `PAPER_INSET`, `PAD_BOUNDARY`, `PAD_BACKING_MIN`, `PAD_BACKING_EVEN`, `FILL_THIN`, `WEDGE_MAX`) were tuned on real ES-580W scans: white paper on the dark front backing, the lighter rear backing, scanner-straightened pages with white fill wedges. If detection gets worse, check new real pages against them before changing the logic.
