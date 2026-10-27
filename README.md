# TextLayer

Adds an invisible text layer to PDFs whose text cannot be read out — pages made of screenshots or
scans, and files whose own text has lost its Japanese — so they can be searched, selected and read
as text. Recognition uses macOS's Vision framework (Japanese and English).

- PDFs that already have sound text are left alone. A page counts as having no text when fewer
  than 10 letters come out of it; a file's own text counts as broken when it is mostly control
  characters, or when it holds less than 60% of the characters Vision reads off the same pages.
- Pages look exactly as before. The text goes in as an incremental update after the original
  bytes, which stay untouched: annotations, links, bookmarks and metadata are kept as they were,
  and the file before the update is its first N bytes.
- On each page that gets the new layer, the page's own content is wrapped in an empty
  `/ActualText`, so readers that honour it (poppler's `pdftotext`, among others) return the new
  text instead of any broken text the page had.
- Files that were updated are marked in their Info dictionary (`/TextLayer`) and skipped next time.

## Usage

```
textlayer check <file-or-folder>...      Show what each PDF needs, without changing anything
textlayer apply [options] <file-or-folder>...
textlayer restore <file>...              Put files back as they were before apply
textlayer watch [options] <folder>       Keep watching a folder and apply to new or changed PDFs

Options for apply and watch:
  --backup-dir <dir>   Where copies of the originals go
                       (default: ~/Library/Application Support/TextLayer/Originals)
  --no-backup          Keep no copies
  --output-dir <dir>   Write updated copies here and leave the originals alone (apply only)
  --jobs <n>           Pages read at once (default: CPU cores - 2)
  --settle <seconds>   How long a file has to stay unchanged before watch reads it (default: 30)
```

Folders are searched recursively; hidden files and folders are skipped. `apply` copies each file
into the backup folder (mirroring its path under your home folder) before changing it and records
it in `log.tsv` there. `restore` cuts the file back to its original length when nothing has
changed it since, and otherwise copies the backup over it.

For a long batch, run it at low priority:

```
nice -n 19 textlayer apply ~/Documents/Papers
```

### Watching a folder with launchd

Save as `~/Library/LaunchAgents/textlayer.watch.plist` (adjust the paths), then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/textlayer.watch.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>textlayer.watch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/you/.local/bin/textlayer</string>
        <string>watch</string>
        <string>/Users/you/Documents/Papers</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>Nice</key><integer>19</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>/Users/you/Library/Logs/textlayer.log</string>
    <key>StandardErrorPath</key><string>/Users/you/Library/Logs/textlayer.log</string>
</dict>
</plist>
```

A folder inside iCloud Drive needs the command to be allowed to read it the first time
(System Settings > Privacy & Security).

## Libraries

- `TextRecognition`: Vision text recognition returning lines with their boxes, and drawing them
  as invisible text into a PDF context — for apps that build searchable PDFs from images.
- `PDFTextLayer`: the PDF reader, the incremental update and the processing used by the command.

## Build

```
xcrun swift build -c release --product textlayer
```

The binary is at `.build/release/textlayer`. Requires macOS 14 or later.

## Credits

The glyphless font used for the invisible text is `pdf.ttf` from
[Tesseract](https://github.com/tesseract-ocr/tesseract), Apache License 2.0.
