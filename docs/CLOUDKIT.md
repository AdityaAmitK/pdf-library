# Sync design

The local library is the source of truth for reading. iCloud (CloudKit private database, through `CKSyncEngine`) is the transfer layer between devices. There is no other backend, analytics or account.

## Storage on each device

`Application Support/PDFLibrary/Libraries/<scope>/`

- `catalog.json`: documents, tombstones, pending-save flags. Written atomically.
- `Files/<uuid>.pdf`: durable copies. The reader opens only these, so every downloaded PDF reads offline.
- `sync-state.plist`: `CKSyncEngine` state, including its pending changes.
- `record-metadata.plist`: CloudKit system fields per record, so saves update records instead of conflicting.

`<scope>` is `icloud-<hash of the iCloud user record ID>` per account, or `local` while signed out. Sync binds to an account library only after iCloud confirms the account's identity; until then (for example an offline launch) the last library stays readable and importable on the device, but nothing is sent or received. Imports, downloads and fetched records that finish after the account changed are not applied to the new library. Libraries of different accounts never mix. PDFs imported while signed out join the first account library that becomes available on that device: they are copied in, and removed from the local library only after the account catalog is written. Signing out shows the (empty or signed-out) local library; the account library stays on disk and returns when the same account signs back in.

## Schema (private database, zone `Library`)

| Record type | Record name | Fields | Changes |
| --- | --- | --- | --- |
| `Document` | `<uuid>` | `title` String, `titleModifiedAt` Date, `createdAt` Date, `byteSize` Int64, `sha256` String, `pageCount` Int64, `deleted` Int64, `deletedAt` Date | on rename, on delete (tombstone) |
| `PDFFile` | `file-<uuid>` | `asset` Asset, `sha256` String | once, at import |
| `Position` | `pos-<uuid>` | `pageIndex` Int64, `pageModifiedAt` Date | at reading checkpoints |

No queries or indexes are needed: `CKSyncEngine` uses zone change tokens.

## Rules

- **PDF bytes are immutable.** The asset is uploaded once in its own record; renames and page changes never re-upload it.
- **Downloads.** Fetched assets are copied out of CloudKit's staging area at once, verified against `sha256`, and moved into `Files/` atomically. Any document still missing its file is requested again after each fetch, when the network returns, at launch and on Retry. Errors show per document until a retry succeeds.
- **Pending work survives restarts.** Every local change sets a pending flag in `catalog.json` and is added to the engine's persisted state; flags clear only when the server confirms the save, and are re-queued at each launch.
- **Position.** Saved only for pages the reader moved to, at most once a second, and when the reader closes or the app goes to the background. Opening a document never writes a position. Last writer wins by `pageModifiedAt`, so moving back intentionally also wins.
- **Rename vs position.** Separate records, so concurrent edits on two devices both survive. Concurrent renames: newer `titleModifiedAt` wins.
- **Delete wins.** Deletion writes a permanent tombstone (`deleted = 1`) on the `Document` record and deletes the file and position records. Tombstones are kept locally forever. A stale device's later rename conflicts with the tombstone and adopts the deletion; a stale position or file record for a deleted document is deleted again by whichever device sees it.
- **iCloud data reset.** Zone deleted or encryption reset: this device uploads its library again. Data deleted by the user in iCloud settings (zone purged): local copies are removed too.
- **Errors.** Quota exceeded shows "iCloud storage is full" on the document and in the sync status, and stays pending. Network and throttling errors are retried by the engine.
- **Clock skew.** Last-writer-wins uses device clocks. Devices with automatic time set agree well enough for reading positions.
