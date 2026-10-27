# TextLayer

> 日本語の説明は[こちら](#日本語)にあります。

`textlayer` adds an invisible, searchable text layer to PDFs whose text cannot be read out — pages
made of screenshots or scans, and files whose own text has lost its Japanese — while leaving how
they look untouched. Recognition runs on your Mac with Apple's Vision framework and is tuned for
Japanese and English, including vertical Japanese.

PDFs that already have sound text are left alone, so it can be pointed at a whole folder, run once
over everything, or left watching a folder for new files.

## Requirements

- macOS 13 or later. Tested on macOS 27 only.
- Vertical Japanese and reading order across columns need macOS 26 or later (Vision's document
  reader). On older systems lines are read horizontally and put in order by layout.
- To build: Xcode or the Xcode Command Line Tools (Swift 5.9 or later).

## Install

Download `textlayer` from [Releases](../../releases), then:

```sh
mkdir -p ~/.local/bin
mv ~/Downloads/textlayer ~/.local/bin/
xattr -d com.apple.quarantine ~/.local/bin/textlayer
chmod +x ~/.local/bin/textlayer
```

The release binary is signed ad hoc, not notarized; `xattr` lets macOS run it. Put
`~/.local/bin` on your `PATH`, or use any folder that is.

### Build from source

```sh
git clone https://github.com/noki1213/TextLayer.git
cd TextLayer
swift build -c release --product textlayer
cp .build/release/textlayer ~/.local/bin/
```

## Usage

```
textlayer check <file-or-folder>...      Show what each PDF needs, without changing anything
textlayer apply [options] <file-or-folder>...
                                         Add a text layer to PDFs that need one
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

Folders are searched recursively; hidden files and folders are skipped. Start with `check`, or
with `apply --output-dir` to look at updated copies before changing anything in place. For a long
batch, run it at low priority:

```sh
nice -n 19 textlayer apply ~/Documents/Papers
```

`apply` copies each file into the backup folder (mirroring its path under your home folder)
before changing it and records it in `log.tsv` there. `restore` cuts the file back to its
original length when nothing has changed it since, and otherwise copies the backup over it.

### Watching a folder with launchd

Save as `~/Library/LaunchAgents/textlayer.watch.plist` (adjust the paths), then run
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

A protected folder (iCloud Drive, Documents, Desktop) has to be opened to the command first:
allow it when macOS asks, or add `textlayer` under System Settings > Privacy & Security >
Full Disk Access. Until then the folder sends no change events and nothing happens; the log says
`can read <folder>` once access is allowed.

## How it works

- **Which PDFs it changes.** A page is read again when fewer than 60 letters come out of it (a
  heading, a date or a page number over pictures or handwriting); reading it again keeps those.
  A file's own text is replaced when it is broken: mostly control characters; mostly unlike what
  is printed; missing its Japanese, or its kanji, in lines whose other characters it has; or a
  layer of invisible text from another OCR over a scan. Text that only misses what is inside
  pictures is kept.
- **Pages look exactly as before.** The text goes in as an incremental update after the original
  bytes, which stay untouched: annotations, links, bookmarks and metadata are kept as they were,
  and the file before the update is its first N bytes.
- **Old text is hidden from text extraction.** Each page that gets the new layer has its own
  content wrapped in an empty `/ActualText`, so readers that honour it (poppler's `pdftotext`,
  among others) return the new text instead of any broken text the page had.
- **Selection follows the lines.** Line boxes are kept from overlapping, since PDFKit groups
  characters into lines by their vertical extent, and lines are written in reading order.
- Files that were updated are marked in their Info dictionary (`/TextLayer`) and skipped next
  time.

## Security & Privacy

Everything runs locally. `textlayer` makes no network connections; PDFs are read and recognized
on your Mac with Vision and written back in place (or to `--output-dir`). Backups and the log stay
in the backup folder on your Mac.

## Known Limitations

- PDFKit (Preview, and apps built on it) ignores `/ActualText`. On a page whose own text was
  replaced, it returns the old text followed by the new one.
- Encrypted PDFs, damaged PDFs whose pages cannot be found, and files that are not PDFs are
  skipped and reported.
- iCloud Drive files that are not downloaded to the Mac are skipped.
- Handwriting is read as well as Vision reads it, which for untidy notes is not very well.

## Libraries

The package also provides two libraries:

- `TextRecognition`: Vision text recognition that returns lines with their corners, reading
  order and line-box separation, and drawing lines as invisible text into a PDF context — for
  apps that build searchable PDFs from images.
- `PDFTextLayer`: the PDF reader, the incremental update and the processing used by the command.

```swift
.package(url: "https://github.com/noki1213/TextLayer.git", branch: "main")
```

## Credits

The glyphless font used for the invisible text is `pdf.ttf` from
[Tesseract](https://github.com/tesseract-ocr/tesseract), Apache License 2.0
(see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).

## License

MIT. See [LICENSE](LICENSE).

---

<a id="日本語"></a>
# TextLayer（日本語）

`textlayer` は、文字が取り出せない PDF（スクリーンショットやスキャンでできたページ、日本語の文字が
壊れたファイル）に、見えない文字の層を足して、検索・選択・テキストとしての読み取りをできるように
するコマンドです。見た目は変わりません。文字の読み取りは Mac の中で Apple の Vision で行い、
縦書きを含む日本語と英語に合わせてあります。

文字が正しく取れる PDF には何もしないので、フォルダごと指定したり、全部に一度かけたり、
フォルダを見張って新しいファイルにかけたりできます。

## 動作環境

- macOS 13 以降。動作確認は macOS 27 のみ
- 縦書きの日本語と、段をまたいだ読む順番には macOS 26 以降が必要（Vision の文書の読み取り）。
  それより前の macOS では、行を横書きとして読み、並びから順番を決める
- ビルドには Xcode か Xcode Command Line Tools（Swift 5.9 以降）

## インストール

[Releases](../../releases) から `textlayer` をダウンロードして、次を実行します。

```sh
mkdir -p ~/.local/bin
mv ~/Downloads/textlayer ~/.local/bin/
xattr -d com.apple.quarantine ~/.local/bin/textlayer
chmod +x ~/.local/bin/textlayer
```

配布しているバイナリはアドホック署名で、公証していません。`xattr` で macOS が実行できるように
なります。`~/.local/bin` を `PATH` に入れるか、`PATH` の通ったフォルダに置いてください。

### ソースからビルド

```sh
git clone https://github.com/noki1213/TextLayer.git
cd TextLayer
swift build -c release --product textlayer
cp .build/release/textlayer ~/.local/bin/
```

## 使い方

```
textlayer check <ファイルかフォルダ>...     各 PDF に何が要るかを表示する（何も変えない）
textlayer apply [オプション] <ファイルかフォルダ>...
                                          文字の層が要る PDF に足す
textlayer restore <ファイル>...             apply の前の状態に戻す
textlayer watch [オプション] <フォルダ>     フォルダを見張り、新しい・変わった PDF に apply する

apply と watch のオプション:
  --backup-dir <dir>   元のファイルの写しを置く場所
                       （既定: ~/Library/Application Support/TextLayer/Originals）
  --no-backup          写しを残さない
  --output-dir <dir>   直した写しをここに書き、元のファイルは変えない（apply のみ）
  --jobs <n>           同時に読むページ数（既定: CPU のコア数 - 2）
  --settle <seconds>   watch が読む前に、ファイルが変わらずにいるべき秒数（既定: 30）
```

フォルダは中まで探し、隠しファイル・隠しフォルダは飛ばします。最初は `check` か、
`apply --output-dir` で直した写しを見てから、元のファイルにかけるのがおすすめです。
時間のかかる一括処理は優先度を下げて動かします。

```sh
nice -n 19 textlayer apply ~/Documents/Papers
```

`apply` は書き換える前に、各ファイルを退避先に（ホームフォルダからのパスのまま）写し、
そこの `log.tsv` に記録します。`restore` は、そのあと誰も書き換えていなければファイルを元の長さに
切り詰め、書き換えられていれば退避した写しで上書きします。

### launchd でフォルダを見張る

英語版の plist を `~/Library/LaunchAgents/textlayer.watch.plist` に保存し（パスは書き換える）、
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/textlayer.watch.plist` を実行します。

保護されたフォルダ（iCloud Drive・書類・デスクトップ）は、先にコマンドに読む許可を出す必要が
あります。macOS に聞かれたら許可するか、システム設定 › プライバシーとセキュリティ ›
フルディスクアクセス に `textlayer` を足してください。許可が出るまではフォルダの変更が届かず、
何も起きません。許可が出るとログに `can read <フォルダ>` と出ます。

## しくみ

- **書き換える PDF**：元の文字が60文字未満のページ（画像や手書きの上の見出し・日付・ページ番号だけ）
  を読み直します。読み直してもそれらの文字は残ります。ファイルの元の文字が壊れているとき（ほぼ
  制御文字、印刷されたものとほぼ違う、ほかの文字はある行で日本語か漢字だけが抜けている、
  スキャンの上にほかの OCR が置いた見えない文字）は置き換えます。図の中の文字が足りないだけの
  文字は残します
- **見た目はそのまま**：文字は元のバイトのあとに増分更新として足し、元のバイトは変えません。
  注釈・リンク・しおり・メタデータはそのまま残り、足す前のファイルは先頭の N バイトそのものです
- **古い文字は取り出しから隠す**：文字の層を足したページは、元の中身を空の `/ActualText` で包むので、
  これに従う読み取り（poppler の `pdftotext` など）は、ページにあった壊れた文字ではなく新しい文字を
  返します
- **選択は行に沿う**：PDFKit は文字の高さの重なりで行をまとめるので、行の枠が重ならないようにし、
  読む順番に書きます
- 書き換えたファイルには Info 辞書に印（`/TextLayer`）を付け、次からは飛ばします

## セキュリティとプライバシー

すべて手元で動きます。`textlayer` はネットワークに接続しません。PDF は Mac の中で Vision で読み、
元の場所（または `--output-dir`）に書きます。退避した写しと記録は、Mac の中の退避先に残ります。

## 既知の制限

- PDFKit（プレビューや、PDFKit を使うアプリ）は `/ActualText` に従いません。元の文字を置き換えた
  ページでは、古い文字のあとに新しい文字が続けて出ます
- 暗号化された PDF、ページが見つからないほど壊れた PDF、PDF でないファイルは飛ばして報告します
- Mac にダウンロードされていない iCloud Drive のファイルは飛ばします
- 手書きは Vision が読める範囲でしか読めず、くずした字はあまり読めません

## ライブラリ

このパッケージは、2つのライブラリも提供しています。

- `TextRecognition`：Vision の文字の読み取り（行の四隅・読む順番・行の枠の重なりの解消）と、
  読んだ行を PDF に見えない文字として描く処理。画像から検索できる PDF を作るアプリ向け
- `PDFTextLayer`：PDF の読み取り、増分更新、コマンドが使う処理一式

```swift
.package(url: "https://github.com/noki1213/TextLayer.git", branch: "main")
```

## クレジット

見えない文字に使うグリフのないフォントは、[Tesseract](https://github.com/tesseract-ocr/tesseract)
の `pdf.ttf` です（Apache License 2.0。[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照）。
