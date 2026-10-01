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
- **Multi-selection** — click to select, Command-click to toggle individual
  items, Shift-click (or Shift+arrow) to select a range, **⌘A** to select all.
  The full viewer shows a single item on its own, or a grid when multiple items
  are selected.
- **File actions** — right-click any item (or use the menu shortcuts) to **Open
  with Default App** (⌘↓) or **Reveal in Finder** (⇧⌘R). Both act on the whole
  selection when the clicked item is part of it.
- **Search** — a scoped search field in the toolbar filters by filename within
  the current scope (the selected folder in Folders mode, or All Media when
  flattened).
- **Keyboard navigation** — arrow keys move the grid selection (Up/Down jump a
  full row); Return or **G** opens the selection in the full viewer; **G**
  or Esc returns to the grid.
- **Full viewer** — double-click, Return, or **G** to open an item:
  - Images: pinch or scroll-wheel to zoom, drag/trackpad to pan. The toolbar
    shows the live zoom level with zoom in/out, **Fit** (F) and **100%** (1)
    buttons; double-click toggles between Fit and 100%.
  - Video & audio: inline AVKit player with transport controls.
  - PDFs: continuous-scroll PDFKit view.
  - Everything else: QuickLook preview.
  - Left/Right arrows move between items; Esc or **G** closes the viewer.
  - The filename shows in a caption bar below the media, so it never overlaps
    the content, and the window toolbar hides while the viewer is open.
- **Refresh** — rescan the current folder with the toolbar button or **⌘R**
  (keeps your sidebar folder selection).
- **Multiple windows** — **⌘N** opens a new empty window; **⌘O** opens a chosen
  folder in a new window. Each window browses independently.

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
