# Loupe

A native macOS media browser inspired by Fileloupe. Drop a folder onto the
window and browse all the images, videos, and PDFs inside it.

## Features

- **Drop a folder to open** — drag any folder onto the window, or use
  `File ▸ Open Folder…` (⌘O) / the **Choose Folder…** button.
- **Flattened by default** — every previewable file in the folder tree is shown
  in one grid, no matter how deeply nested.
- **Folder sidebar** — switch to **Folders** mode (or click a folder in the
  sidebar) to browse one directory at a time. The sidebar shows the full folder
  tree with per-folder media counts.
- **Thumbnails** — fast QuickLook-generated thumbnails with an adjustable size
  slider, plus sorting by name, date, size, or kind.
- **Full viewer** — double-click (or press Return) to open an item:
  - Images: scroll/pinch to zoom, drag to pan, double-click to toggle zoom.
  - Video & audio: inline AVKit player with transport controls.
  - PDFs: continuous-scroll PDFKit view.
  - Everything else: QuickLook preview.
  - Arrow keys move between items; Esc closes the viewer.

## Requirements

- macOS 14 or later
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
build-app.sh               Builds and packages Loupe.app
```
