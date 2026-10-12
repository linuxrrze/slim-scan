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

## Open ideas

None of these are decided:

- **`--crop sides` leaves a strip of backing:** about 15 mm of feeder backing can remain below the sheet. Should "sides" also cut that bottom strip?
- **Center alignment:** `epsonds` reports the ADF as center aligned. A fixed paper size with a left offset of 0 may sit off-center through SANE. Check on paper.
- **Scan more pages without review:** pressing Scan again adds pages only while the review is open. Without review, each scan is its own document.
- **German screenshots:** `gui/tools/screenshots.py` renders the German shot in English when the system lacks the `de_DE` locale.
- **Detection constants:** the paper-detection constants in slim_scan.py (`PAPER_MIN_CONTRAST`, `PAPER_INSET`, `PAD_BOUNDARY`, `PAD_BACKING_MIN`, `PAD_BACKING_EVEN`, `FILL_THIN`, `WEDGE_MAX`) were tuned on real ES-580W scans: white paper on the dark front backing, the lighter rear backing, scanner-straightened pages with white fill wedges. If detection gets worse, check new real pages against them before changing the logic.
- **Lint:** `gui/tests/test_installer.py` imports `sys` without using it.
