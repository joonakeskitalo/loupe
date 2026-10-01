# Loupe

A native macOS media browser inspired by Fileloupe. Drop a folder onto the
window and browse all the images, videos, PDFs, Markdown, and text files
inside it.

## Features

- **Drop a folder or file to open** — drag a folder onto the window to browse
  it, or drop a single file to open it. You can also use `File ▸ Open Folder…`
  (⌘O) / the **Choose Folder…** button.
- **Multiple folders per window** — drop or add more folders at any time and
  they're appended, not replaced. All Media spans every added folder, and each
  folder gets its own section in the sidebar. Use **Add Folder…** at the bottom
  of the sidebar to add more, and the minus button (or right-click → Remove
  Folder) on a folder's header to remove it.
- **Open via the Dock** — drop folders or files onto Loupe's Dock icon (or use
  Finder's "Open With"), and they open in a new window.
- **Flattened by default** — every previewable file in the folder tree is shown
  in one grid, no matter how deeply nested.
- **Folder sidebar** — switch to **Folders** mode (or click a folder in the
  sidebar) to browse one directory at a time. The sidebar shows the full folder
  tree with per-folder media counts.
- **Thumbnails** — fast QuickLook-generated thumbnails with an adjustable size
  slider, plus sorting by name, date, size, or kind.
- **Multi-selection** — click to select, Command-click to toggle individual
  items, Shift-click (or Shift+arrow) to select a range, **⌘A** to select all.
  The full viewer shows a single item on its own, or a grid when multiple items
  are selected.
- **File actions** — right-click any item (or use the shortcuts) to **Open with
  Default App** (⌘↓) or **Reveal in Finder** (F1). Both act on the whole
  selection when the clicked item is part of it.
- **Flag for later** — flag files to triage them within a session. Press **F**
  (or **⌘K**, or right-click → Flag) to flag/unflag the selection; flagged
  thumbnails show an orange flag badge. The sidebar's **Flagged** entry (under
  Library, alongside All Media) scopes the grid to just the flagged files, with
  a live count; **⇧⌘F** toggles it too. Flags are per-window and reset when you
  open a new folder or close the window.
- **Search** — a scoped search field in the toolbar filters by filename within
  the current scope (the selected folder in Folders mode, or All Media when
  flattened).
- **Type & extension chips** — a chip bar above the grid lets you filter by
  media type (Images, Videos, PDFs, Audio, Markdown, Text) and/or specific file
  extensions. Clicking a chip filters by just that one; Shift- or ⌘-click adds
  or removes chips to filter by several at once. Chips show live counts, and a
  Clear chip resets them. The bar appears only when there's more than one type
  or extension to distinguish.
- **Keyboard navigation** — arrow keys move the grid selection (Up/Down jump a
  full row); Return or **G** opens the selection in the full viewer; **G**
  or Esc returns to the grid.
- **Full viewer** — double-click, Return, or **G** to open an item:
  - Images: pinch or scroll-wheel to zoom, drag/trackpad to pan. The toolbar
    shows the live zoom level with zoom in/out, **Fit** and **100%** buttons;
    double-click toggles between Fit and 100%. Zoom hotkeys: **⌘+** / **⌘−**
    zoom in and out (bare **+** / **−** also work), **⌘0** or **F** fits, and
    **⌘1** or **1** shows actual pixel size.
  - Video & audio: AVKit playback with a custom transport bar below the video
    (play/pause, scrubber, time) so controls never cover the picture; Space
    toggles play/pause.
  - PDFs: continuous-scroll PDFKit view.
  - Markdown: rendered with formatting (headings, lists, emphasis, links).
  - Text & source files: shown monospaced with selectable text.
  - Everything else: QuickLook preview.
  - Left/Right arrows move between items; Esc or **G** closes the viewer.
  - The filename shows in a caption bar below the media, so it never overlaps
    the content, and the window toolbar hides while the viewer is open.
- **Refresh** — rescan the current folder with the toolbar button or **⌘R**
  (keeps your sidebar folder selection).
- **Multiple windows** — **⌘N** opens a new empty window; **⌘O** opens a chosen
  folder in a new window. Each window browses independently.

## Requirements

- macOS 15 or later
- Xcode 16 / Swift 6 toolchain

## Build & run

The project is a Swift Package. To build and launch a proper `.app` bundle:

```bash
./build-app.sh release
open Loupe.app
```

For quick iteration during development you can also use `swift run`, though some
system features (sandboxed file access, QuickLook) behave best inside the signed
`.app` bundle produced by `build-app.sh`.

## Project layout

```
Sources/Loupe/
  LoupeApp.swift            App entry point + menu commands
  Model/
    MediaItem.swift         File model + media-type classification
    MediaKind                (image / video / pdf / audio / other)
    FolderNode.swift        Sidebar folder-tree node
    FolderScanner.swift     Recursive scan -> flat list + folder tree
    ThumbnailProvider.swift QuickLook thumbnail generation + cache
    BrowserModel.swift      Observable app state (mode, sort, selection)
  Views/
    ContentView.swift       Split view, drag-and-drop, toolbar
    DropZoneView.swift       Empty-state drop target
    FolderSidebar.swift      Folder tree navigation
    BrowserGridView.swift    Thumbnail grid
    ThumbnailView.swift      Single thumbnail cell
    MediaViewer.swift        Full-item viewer (image/video/pdf/QuickLook)
    FullScreenViewer.swift   macOS full-screen overlay helper
Resources/
  Info.plist               App bundle metadata
  Loupe.entitlements       App-sandbox + user-selected file access
  AppIcon.svg              App icon source (vector)
  AppIcon.icns             Generated multi-resolution app icon
build-app.sh               Builds and packages Loupe.app
make-icon.sh               Renders AppIcon.svg -> AppIcon.icns (all sizes)
```

## App icon

The icon is authored as a single vector file at `Resources/AppIcon.svg` (a
magnifying loupe over a photo stack). To regenerate the `.icns` after editing
the SVG:

```bash
./make-icon.sh
```

`build-app.sh` bundles `Resources/AppIcon.icns` into the app and `Info.plist`
references it via `CFBundleIconFile`. Icon rendering uses `rsvg-convert`
(install with `brew install librsvg`) plus the built-in `iconutil`.
