# Storage Explorer

Storage Explorer is a metadata-only, user-initiated disk usage browser. It does not open file contents during scanning. Selecting a local regular file in the inspector can request a Quick Look preview.

## Scanning and shared metadata

`MacToolsFileSystem` is a static module shared with Disk Clean. Its bulk parser preserves the existing Disk Clean attribute contract; Storage Explorer requests additional allocation, modification date, and file flag attributes. Unsupported bulk reads fall back to descriptor-relative enumeration. Directory opens reject symbolic-link path components. Unreadable directories, cloud-only directories, mount boundaries, invalid filename encodings, and missing metadata make results incomplete instead of appearing empty and complete.

The scanner defaults to two workers, capped at four. Blocking calls stay outside Swift's cooperative executor. Progress is time-throttled to 150 ms with initial and final updates. Cancellation is checked between batches and jobs; a blocking filesystem syscall cannot be forcibly interrupted. Packages remain atomic in the results, with nested payload included. Hard links are deduplicated across all workers and package boundaries; the first encountered link receives the counted bytes.

The app scanner retains every directory, the largest file in each directory, and the 50,000 largest files overall. Omitted small files remain represented by aggregate tiles. Full-tree scanner clients can opt into publishing every file. The main workspace focuses on size on disk in a hierarchical treemap; the largest top-level items receive the warmest stable colors, and descendants inherit their group color. Size on disk is not a promise of recoverable disk space.

## Refresh and retention

Scanning starts only when the user chooses a folder, scans Home, or clicks Refresh. Navigation, selection, Trash success, and Trash failure never trigger another scan. Refresh clears the directory metadata cache and reads fresh metadata; during refresh, the previous complete visualization remains stable until the replacement snapshot is ready. External filesystem changes are reflected only after an explicit refresh, while Trash still verifies item identity and type immediately before execution. Recent snapshots are cached locally for an immediate preview during a requested scan; cached previews cannot be reviewed for Trash. No scan paths or results are sent over the network.

Trash review is unavailable during scanning, for cached previews, symbolic links, and protected paths. Symbolic links remain visible and can be revealed in Finder, but Storage Explorer does not follow or remove them. Hard-linked files preserve their real file size for validation while scan accounting counts the shared data once; the inspector explains that space is released only after the final link is removed. Items can be added with the plus button or by dragging them from the treemap or compact list to the always-visible review basket. The basket normalizes ancestor/descendant overlap. Trash operations verify file identity, move the verified object into a private sibling staging directory, verify it again, and then give the staged path to macOS Trash. Partial failures restore items when their original names are still available and keep failed items selected for retry.

Confirmed Trash successes remove the corresponding subtrees from the in-memory snapshot and local preview cache. Ancestor sizes, counts, file-type summaries, and the visualization update from recorded totals, including totals for omitted small files. Navigation returns to the closest surviving ancestor if the current folder was removed. Counted hard-link bytes transfer to a surviving retained link when one is available. These adjusted sizes remain snapshot estimates: external changes, unretained hard links, and physical space recovery require an explicit refresh or separate disk-space measurement.

## Validation

Run the StorageExplorer scanner, progress, controller, presentation, and safety-policy XCTest classes, plus DiskClean bulk-parser and walker tests. Run `make script-tests` after changing module/project integration. Benchmark optimized builds on synthetic many-small-file trees, deep trees, packages, and sparse files; compare full duration, first useful update, callbacks, and memory separately. Local synthetic benchmarks do not establish external-drive, cloud-provider, or network-filesystem performance.

The standalone benchmark creates and deletes only its own temporary fixture:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer python3 scripts/benchmark-storage-explorer.py --files 100000
```

The benchmark reports duration, callback count, retained node count, cache reuse, and process peak resident memory. Its progress-only run enforces a 200 MiB peak-memory ceiling by default. This is a warm-filesystem synthetic check, not a cold-disk or external-drive guarantee.
