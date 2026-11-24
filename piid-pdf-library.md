# PIID — PDF Library for Mac, iPhone and iPad
> Aditya, 2026-11-25. Continue reading the same PDF on any of my Apple devices, with a reader suited to each device and the entire library available offline.

# 1. Context
## Problem
A PDF started on one device should be ready on the others, at the last page read.
## Why this needs a fix
Aditya switches among Mac, iPhone and iPad and wants the continuity he expects from Streamy, without manually moving files or finding his page.
## Goal
Native personal app with one private iCloud library, automatically downloaded copies, synced reading position, rename and delete. Deliver merged code and local build/runtime evidence. Physical iPhone and iPad installation and cross-device verification follow when Aditya reconnects them.

# 2. References & Blast Radius
- Import from Files or Finder into an app-managed copy. Support a native file picker and Mac drag-and-drop. Add share import where practical within this delivery, but the picker is the primary acceptance path.
- Open from a local library using PDFKit. Provide an iPhone-focused reader, iPad split layout and Mac sidebar with keyboard controls. Use platform-appropriate defaults and adapt to available width.
- Sync through the private database in a dedicated iCloud container. Use local durable storage for all PDFs and catalog data. [CloudKit platform guidance](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app) · [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) · [CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)
- Streamy reference at /Users/aditya/Developer/streamy/docs/piid-ios-cloudkit-sync.md. Historical signing notes are useful, but validate the new app independently and leave Streamy untouched.
- Baseline 2026-11-25 IST. New app baseline commit 2d3e19d. Streamy reference HEAD 2d0dfd9. If repo behavior has drifted since this commit, stop, flag it to the user, and rework this piid.

# 3. Analysis
## Solution
- SwiftUI and PDFKit, shared code for native macOS and universal iOS/iPadOS. Apple-only iCloud sync, with no custom backend, analytics or third-party accounts.
- Import immutable PDF bytes and keep them in durable app storage. Use stable document IDs. Prefer separate CloudKit records for the asset and frequently changing state if that avoids repeat transfers. Persist sync state and pending changes across restarts. Copy incoming staged assets promptly and atomically. Automatically request and retain every PDF, report pending downloads and recoverable errors, and resume after reconnect or next launch. iCloud scheduling and storage limits govern when the entire library becomes ready.
- Sync position per document at safe checkpoints. Opening a document without reading must not overwrite newer progress. Support intentional backwards navigation. Merge concurrent rename and position changes independently. Make deletion win against stale offline edits, with tombstones or an equivalent durable guarantee. Keep libraries isolated across iCloud account changes.
- Keep local reading and import usable when iCloud is temporarily unavailable. Keep personal files and secrets out of Git. Use a synthetic multi-page PDF for runtime proof. Handle invalid imports, quota and storage errors in the UI.
## Iterations
**Preliminary solution:** Treat iCloud as the transfer layer and keep local copies as the source for the reader.
**Findings:** Offline availability requires durable copies rather than relying on the CloudKit asset staging location. Separate position and rename updates from PDF transfer. Physical iPhone/iPad are unavailable, so distinguish verified simulator behavior from pending real-device sync.

# 4. Implementation Instructions
1. Create the shared native app targets and signing configuration. Use one dedicated app ID/container strategy across platforms, with documented Apple provisioning steps and private database schema. Preserve buildability in environments without signing.
2. Implement local library, PDF import, reader layouts, last-page resume, rename and confirmed delete. Use the configured UI design specialty in the project when applicable.
3. Connect CloudKit sync over the local library. Verify restart durability, auto-download, error visibility, offline behavior, merge rules and account isolation. Keep the UI usable while transfers run. Use Apple APIs and minimize dependencies.
4. Build on Mac and for iPhone/iPad. Exercise available local runtime paths using T3 device tools and synthetic PDFs. Use live iCloud evidence where legitimately available and state any gap. Write a short runbook for signing and the later real-device smoke test covering import, page resume, rename, delete and airplane-mode reopen across devices.
5. Run the user-configured three-member read-only council on the exact candidate head, collect independent scores, fix material findings and get fresh review as needed. Require each score at least 8.5/10 plus the full-send merge conditions. Open and merge a private PR once gates pass. Do not add or modify test code or inline self-check scaffolding.

# 5. Forced PDF dark mode
- Add a persistent, explicit Force PDF Dark Mode setting across all platforms, available even when the system theme is light. Scope it to the PDF reader. Default off and apply immediately to the current document.
- Use a dark reading surface and selectively render PDF text for contrast. Preserve the original colors of embedded images and non-text artwork. A whole-page inversion, filter, or pixel-color threshold cannot satisfy this. PDF text rendered into a scan is part of the source image and remains original. Preserve the original PDF bytes.
- Investigate PDFKit/Core Graphics rendering capabilities before implementation. Reuse the platform reader where feasible. If a specialized rendering path is needed, make it a real reader with correct zoom, scrolling, page tracking and restoration. Handle unsupported constructs faithfully and make any limitations visible. Do not claim compliance for a filter that inverts images or a toggle that only darkens the app chrome.
- Manually verify with a synthetic PDF containing selectable dark text, a color photo, colored vector artwork and an image-only page. With the system in light mode, switch the setting on and off, compare image colors and text contrast, reopen the reader, and verify persistence, page navigation and position tracking. Include this in the exact-head council review.
