# slim-scan

A CLI that scans every page from a scanner's document feeder into one PDF, plus **Slim Scan**, a GTK 4 / libadwaita desktop app built on it. Developed against the Epson ES-580W. User-facing docs: [README.md](README.md) (CLI) and [gui/README.md](gui/README.md) (app). Findings that the code doesn't show, plus open ideas: [docs/NOTES.md](docs/NOTES.md).

## Layout

- `slim_scan.py`: the whole CLI and core, in a single file that uses only the **Python standard library** (3.9+). This includes:
  - both backends: **WSD** (the default, implemented in Python) and **SANE** (through `scanimage`)
  - JPEG/TIFF parsing, blank-page detection, paper size, straightening and orientation
  - the OCR pipeline (`PageOcr`, `parse_tsv`, `text_layer`)
  - the PDF writer, including the invisible text layer
- `gui/slim_scan_gui.py`: the app.
- `gui/scanform.py`: GUI logic without GTK, tested without a display.
- `gui/tray.py`: the status bar icon over D-Bus.
- `gui/i18n.py`: loads `gui/po/*.po` directly.
- `gui/slim_scan.py` is a **symlink** to the root `slim_scan.py`. Edit the root file only.
- `gui/install.sh` installs for one user or the whole system; `--dist` builds a tarball.
- `gui/data/`: the .desktop file, AppStream metainfo and icons. The app's own symbolic icons are `gui/data/icons/slim-scan-*-symbolic.svg`.
- `debian/`: Debian packaging for `slim-scan` (CLI) and `slim-scan-gui`; `gen-changelog.sh` writes the ignored `debian/changelog` from `VERSION`, `publish-apt.sh` updates the apt repository. `.github/workflows/deb.yml` builds and tests them; a `vX.Y.Z` tag publishes a GitHub Release and the apt repository on GitHub Pages. See docs/NOTES.md.
- `nextcloud-plugin/` is ignored by git and is not part of this repository. Don't touch it.

## Rules

- **No third-party Python packages** in `slim_scan.py` or its tests. The app may use only PyGObject (GTK 4.12+, libadwaita 1.5+).
- External tools are called with absolute paths and validated arguments, never through a shell. Device texts are untrusted:
  - sanitize them before printing
  - the GUI shows them as plain text, never as markup

  The limits and checks are listed under "Security" in README.md; `tests/test_security.py` guards them. Keep both in step.
- The core reports progress to the GUI through `on_event` callbacks (`report(kind, n)`). For a new event kind:
  - handle it in `gui/slim_scan_gui.py` (`on_progress`)
  - give it a text in `gui/scanform.py` (`progress_text`)
- OCR: Tesseract is preferred and runs per page while scanning, one process per page, in parallel (`PageOcr`). OCRmyPDF runs once on the saved PDF. "Automatic" picks the first available tool in `OCR_ENGINES`.
- Fix scanner/backend bugs upstream (SANE) rather than adding workarounds here. Record them in docs/NOTES.md.
- **Never commit real scans** (`scan_*.pdf` is ignored). They may contain personal documents. Test pages are synthetic or come from the fakes.

## Tests

From the repository root:

```sh
python3 -m unittest discover -s tests -v       # core: about 40 s, stdlib only
python3 -m unittest discover -s gui/tests -v   # app logic; the GTK tests need a display
```

- `tests/fake_wsd.py` is a fake WSD scanner on localhost. `ES580W_PROFILE` in the tests models the real device.
- `tests/fake_sane.py` stands in for `scanimage`, with the ES-580W's real option lists.
- `tests/fake_ocr.py` stands in for `tesseract` and `ocrmypdf`. Set `FAKE_OCR_DELAY` and `FAKE_OCR_FAIL` to make them slow or fail.
- The tests set `SLIM_SCAN_CONFIG` to a temporary file, so they never read the real config. Keep it that way in new tests.
- `gui/tests/test_gui_gtk.py` skips itself without GTK 4.12+/libadwaita 1.5+ and a display. Run it with `xvfb-run` or under a headless Weston.
- When the real scanner behaves unexpectedly, record that behavior in the fake profile and add a test.

## After changing the app

- **Texts:** mark user-visible strings with `_()`, `ngettext()` or `pgettext()`. Then run `python3 gui/tools/update_po.py` and translate the new empty `msgstr` entries in `gui/po/de.po`. The tests fail on incomplete catalogs and on catalogs that are out of date.
- **Visible UI changes:** regenerate the screenshots with `python3 gui/tools/screenshots.py docs/screenshots` (this needs GTK and a display). Look at the PNGs before committing them. Don't commit shots that differ only in the date.
- **Docs:** update README.md and gui/README.md, and the metainfo feature list if needed, in the same commit as the change.

## Style

- Match the surrounding code: plain functions, short docstrings, sparse comments that say *why*.
- Docs and commit messages are plain English in short, direct sentences, describing behavior from the user's point of view. Include measurements where they matter.
- Commit messages: an imperative subject, optionally prefixed with the area (`GUI: …`, `OCR: …`, `README: …`). The body explains the why and the effect.
