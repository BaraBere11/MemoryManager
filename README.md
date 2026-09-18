# Memory Manager - MacOS

A native macOS app that shows what is using your **RAM** and your **disk**, in two tabs.

Built with SwiftUI and SwiftPM. **Xcode is not required** — the Command Line Tools
toolchain is enough.

## Build and run

```sh
./build.sh --run
```

That produces `build/Memory Manager - MacOS.app`. Drag it to `/Applications` if you want to keep it.

```sh
./build.sh debug     # debug build
./build.sh           # release build, no launch
swift build          # binary only, no .app bundle
```

## Memory tab

Live, auto-refreshing (1–10 s, selectable).

- **Breakdown bar** — App Memory / Wired / Compressed / Cached Files / Free, using the
  same definitions as Activity Monitor. Numbers come from `host_statistics64(HOST_VM_INFO64)`,
  with the total from `hw.memsize`.
- **Memory pressure** — the kernel's own verdict, read from
  `kern.memorystatus_vm_pressure_level` (Normal / Warning / Critical), plus a sparkline
  of the non-reclaimable share of RAM over the last ~90 samples.
- **Swap** — from `vm.swapusage`.
- **Process table** — sortable and filterable, showing each process's **physical footprint**
  (`proc_pid_rusage`), the same number Activity Monitor puts in its Memory column. Helper
  processes show the app they belong to, so `Code Helper (Renderer)` is labelled
  *Visual Studio Code*.
- **"What it is"** — a plain-language description of each process. Click a row for a detail
  pane with the full text and the executable's path.
- **Quit / Force Quit** — from the detail pane or by right-clicking a row.

### Quitting processes

**Quit** sends `SIGTERM`, asking the process to exit and save its work. **Force Quit** sends
`SIGKILL`, which it cannot catch or ignore. Both always confirm first.

Each process is assessed before the confirmation appears, and the dialog says what will
actually happen:

| Risk | Meaning |
| --- | --- |
| Blocked | `launchd` and `kernel_task`. Refused outright — killing `launchd` panics the machine. The refusal is enforced in `ProcessKiller`, not just hidden in the UI. |
| Severe | Ends your login session or loses unsaved work: `WindowServer`, `loginwindow`, `securityd`, `configd`, and similar. The warning names the specific consequence. |
| Caution | A system process. Usually restarted automatically — `Dock` and `Finder` say so explicitly. |
| Normal | An ordinary app or helper. |

Processes owned by another user cannot be signalled directly. When that happens the app
says so and offers to retry with administrator rights; macOS then shows its own password
dialog. The password is never seen or handled by this app — the retry runs
`do shell script … with administrator privileges`.

Some processes are protected by System Integrity Protection and will not die even with
administrator rights. The app reports that plainly rather than silently failing.

### Where the descriptions come from

Two sources, and the app distinguishes between them.

**A catalogue of about 130 known processes**, mostly the Apple daemons that show up with
cryptic names and non-trivial memory use — `mds_stores` is the Spotlight index,
`WindowServer` composites the screen, `tccd` is what asks whether an app may use your
camera. Chromium and Electron helpers are recognised by role, so a `(Renderer)` is
described as rendering one tab of its parent app.

**Everything else is described from where the executable lives**, which is factual rather
than guessed: something in `/System/Library/Foo.framework` is reported as part of Apple's
Foo framework, something in `/opt/homebrew` as installed by Homebrew. These inferred
descriptions are shown in a dimmer colour, and the detail pane says explicitly that the
text comes from the install location rather than from knowledge of that program.

On a typical system the catalogue covers roughly 30 of the 50 largest processes, which is
where the cryptic names cluster. Nothing is ever invented for a process the app does not
recognise.

### About the `~` marker in the process list

Reading another user's process footprint requires a privilege this app does not have
(Activity Monitor gets it from a special Apple entitlement). On a typical system that is
roughly a third of all processes — mostly root-owned daemons.

Rather than hide them, those rows fall back to **resident size** read via `/bin/ps`, which
is setuid-root and can see every process. Those rows are marked `~`, and the count is shown
next to the table heading. RSS counts shared memory once per process, so those figures run
a little high; the rest are exact.

## Storage tab

- **Capacity** is read instantly from the volume, with no scan — total, used, and available
  (using `volumeAvailableCapacityForImportantUsage`, the figure Finder shows, which counts
  purgeable space).
- **Scan** walks your home folder and `/Applications` and breaks the space down by category:
  Applications, Documents, Desktop, Downloads, Photos & Media, Developer, Caches, App Data,
  Other in Home, and the remainder as System & Other. Expect roughly 20–40 s for ~800k items.
- **Folder browser** — click a row to select it, double-click (or use the chevron) to drill in.
  Each child shows a bar for its share of its parent. Right-click to reveal in Finder or copy
  the path.
- **The scan itself never modifies anything.** It only reads file sizes. Deleting only happens
  when you explicitly ask for it, below.

### Deleting files and folders

Select an item and use **Move to Trash** or **Delete…** in the bar above the browser, or
right-click any row. Both always confirm first, and the confirmation states the size, the
full path, and what will actually happen.

**Move to Trash** is reversible — the item goes to `~/.Trash` and you can put it back. Note
that **this does not free any space until you empty the Trash**; the app says so after every
trash operation rather than letting you believe space was reclaimed.

**Delete…** removes the item immediately and frees the space. It cannot be undone, and the
confirmation says so plainly.

Some things are refused outright, and the refusal lives in `FileRemover`, not just in the UI:

| Protected | Why |
| --- | --- |
| `/`, `/System`, `/Library`, `/Users`, `/Applications`, `/usr`, `/etc`, … | Removing any of these breaks the installation. |
| Your home folder | It holds your entire account. |
| The standard home folders — Desktop, Documents, Downloads, Library, Movies, Music, Pictures, Public, `.Trash` | Part of the account's structure. You can delete things *inside* them, just not the folders themselves. |

Everything else is allowed but rated, and the rating appears in the confirmation:

- **Severe** — anything in `~/Library` outside Caches. Removing it can lose settings,
  licences or saved state for the app that owns it.
- **Caution** — `~/Library/Caches` (rebuilt automatically) and `.app` bundles (you would
  need to reinstall).
- **Normal** — ordinary documents and downloads.

After a deletion the browser and the category breakdown update in place — the item is
removed from the tree and its size is subtracted from every parent — so you do not have to
sit through another full scan to see the result.

If macOS refuses the removal, the app reports it and points at Full Disk Access rather than
failing silently. It never attempts a privileged delete.

Categories always add up to the volume's used space: whatever the scan does not walk
(`/System`, `/usr`, other user accounts, anything permissions block) lands in
*System & Other*.

### Permissions

macOS will ask for access to Desktop, Documents, and Downloads the first time you scan.
Denying them just means those folders read as empty and their bytes fall into
*System & Other*; the count of unreadable folders is shown under the Scan button.

For a complete picture, grant the app **Full Disk Access** in
System Settings → Privacy & Security.

## Accuracy notes

- Sizes are **allocated size on disk** (`totalFileAllocatedSize`), so they match Finder's
  "Size on disk" rather than the logical file length.
- Symlinks are skipped, and the scan never crosses onto another mounted volume, so nothing
  is counted twice through those paths.
- APFS **clones** (copy-on-write duplicates) are counted once per path, so a cloned file
  appears in the total for each copy even though it occupies the space only once. Finder
  behaves the same way.
- Folders under 2 MB are rolled into their parent instead of being kept as separate rows.
  They still count toward every total — this only bounds how much tree is held in memory.

## Layout

```
Sources/MemoryManager/
  App.swift                  window, tab switcher
  Memory/
    MemorySampler.swift      host_statistics64, sysctl, swap, pressure
    ProcessSampler.swift     per-process footprint, ps fallback, naming
    MemoryModel.swift        refresh loop and filtering
  Disk/
    VolumeSampler.swift      mounted volumes and capacity
    DiskScanner.swift        parallel tree scan, pruning, categories
    DiskModel.swift          scan lifecycle, progress, cancellation
  Views/
    MemoryView.swift, DiskView.swift, Components.swift
Resources/Info.plist         bundle metadata and permission strings
build.sh                     build + assemble the .app
```
