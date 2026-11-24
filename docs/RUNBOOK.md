# Real-device smoke test

Physical iPhone/iPad checks were deferred when this app was first built. Run these once the devices are connected and SIGNING.md is done. Use a synthetic multi-page PDF (no personal documents) that has selectable text, a color photo, colored vector artwork and an image-only (scanned) page.

## Setup

1. All three devices signed in to the same Apple ID with iCloud Drive on. Automatic date & time on.
2. Install signed development builds: Mac (`PDFLibraryMac`), iPhone and iPad (`PDFLibraryiOS`) from Xcode.
3. Open the app on each device once; the sync status should read iCloud (not "iCloud off").

## Checks

| # | Step | Expected |
| --- | --- | --- |
| 1 | Mac: Import the sample PDF (⌘O, and once by dragging from Finder). | Appears once (duplicate import is reported). Status shows uploading, then in iCloud. |
| 2 | iPhone and iPad: wait, or pull Retry. | The PDF appears and downloads by itself; no tap needed to fetch it. |
| 3 | iPhone: open it, read to page 7, close. | iPad and Mac list "Page 7 of 12". Opening there resumes at page 7. |
| 4 | iPad: open (lands on 7), close without scrolling. | iPhone still shows page 7 (opening didn't overwrite). |
| 5 | Mac: go back to page 3 deliberately. | Others show page 3 (intentional backwards navigation wins). |
| 6 | Airplane mode on iPhone: rename the PDF; on iPad (online) move to page 9. Turn airplane mode off. | Every device shows the new title and page 9. |
| 7 | Airplane mode on iPad: open the PDF. | Opens and reads fully offline (local copy). |
| 8 | iPhone offline: move to page 11. Mac online: delete the PDF (confirm). iPhone back online. | The PDF disappears everywhere and doesn't come back. |
| 9 | Force quit during an upload of a large PDF; relaunch. | Upload resumes; the other devices receive it. |
| 10 | Sign out of iCloud on the iPad (or use a second Apple ID). | Library shows "iCloud off — local library"; the account's PDFs aren't shown; signing back in restores them. |

## Forced PDF dark mode (each device, system appearance Light)

1. Open the sample PDF. Turn **Force PDF Dark Mode** on in the reader toolbar.
2. Text page: dark surface, light text; blue/red text keeps its hue. The photo's colors match the light rendering exactly.
3. Artwork page: shapes, lines and gradient keep their colors; labels turn light.
4. Scanned page: shown as scanned (its text is part of the image); the reader notes this.
5. Toggle off and on: applies immediately, same page and zoom, and doesn't change the saved reading position.
6. Close and reopen the reader, then relaunch the app: the setting persists; page navigation and position sync behave as above.

Record results (device, OS version, pass/fail, notes) in the PR or an issue.
