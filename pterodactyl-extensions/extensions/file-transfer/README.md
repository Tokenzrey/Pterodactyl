# File Transfer

Two buttons in the server file manager: **Upload large file** (a file the browser cuts into pieces, so one too big for a single request still gets there) and **Fetch from address** (the Panel downloads a file from a URL and puts it on the server).

## Installation

```bash
p:extension:install file-transfer --enable
```

## Settings

Admin → Extensions → File Transfer:

| Setting | Range (default) | Meaning |
|---|---|---|
| Chunk size | 1–10 MB (5) | Size of each piece. Public: the browser reads it. |
| Largest upload | 1–10240 MB (2048) | Largest file sent in pieces. Public: the browser refuses a larger file before sending anything, and the Panel refuses it again. |
| Largest download | 1–10240 MB (1024) | Largest file the Panel fetches from a URL. |
| Clean up after | 1–24 h (2) | Unfinished uploads and downloads older than this are deleted every 30 minutes (`file-transfer:cleanup`). |

## How it works

**Upload.** The browser reads one piece at a time, takes its SHA-256, adds it to the SHA-256 of the whole file, and posts it as base64 to `POST …/extensions/file-transfer/chunk`. The Panel checks the piece's checksum and stores it under the upload id. `POST …/chunk/merge` joins the pieces, checks the checksum of the whole file, and streams the result to Wings (`files/write`). A network error or 5xx is retried three times; a 429 is waited out for as long as `Retry-After` says. The route allows 30 requests a minute per user, so a 2 GB file in 5 MB pieces takes about 14 minutes; use 10 MB pieces to halve that.

**Fetch.** `POST …/remote-fetch` answers `202 {job_id}` at once and queues `FetchRemoteFile`. The dialog follows the job with the Panel's progress API (`useExtensionJobProgress`), so it survives closing the window. A failure carries a fixed code (`invalid_url`, `download_failed`, `download_too_large`, `timeout`, `connection_refused`, `upload_failed`) that the dialog turns into words.

## Permissions

| Permission | Needed for |
|---|---|
| `file.create` | Upload large file (the Panel checks it on both upload routes). |
| `ext.file-transfer.remote-fetch` | Fetch from address (the Panel checks it on that route). The two are independent, so grant fetch only to subusers who may add files to the server. |

## Security

- **SSRF.** Only `http` and `https`, no user name or password, a real host name or a public IP. Loopback, private, link-local, CGNAT, multicast, reserved, IPv4-mapped, NAT64, 6to4, Teredo and unique-local ranges are refused, as are `inet_aton` spellings such as `0x7f.1` and `2130706433`. The host is resolved once, every address must be public, and the connection is pinned to the address that was checked (`CURLOPT_RESOLVE`), so a second lookup cannot rebind it. Redirects are followed by hand, at most 3, only to `https`, and each one goes through all of the above.
- **Paths.** Upload ids are UUIDs and nothing else; file names and folders are checked with `\A…\z` (not `^…$`) and refuse `..`, a leading `/`, `//` and anything outside `[A-Za-z0-9_./-]`.
- **Limits.** Size is checked before the first piece is written and again while merging and downloading. One merge per upload at a time (`Cache::lock`). Chunks, merged files and downloads are removed when done and by the cleanup command when abandoned.
- Errors shown to the user are fixed texts; nothing the remote server or Wings said is passed on. Logs carry class names, ids and counts, never URLs or file contents.

## Testing

```bash
tools/pest.sh file-transfer    # backend: unit + integration
tools/build.sh file-transfer   # typecheck + Vitest + build + prefixed-class check
```

## Traceability

| Requirement | Tests |
|---|---|
| Chunk validation, path traversal (FR-FT1–5, AC-FT19, T-FT3) | `ChunkValidatorTest`, `PathValidatorTest`, `ChunkControllerTest`, `MergeControllerTest` |
| Chunk store, cleanup (FR-FT17, NFR-FT5) | `ChunkStoreTest`, `CleanupCommandTest` |
| SSRF, DNS rebinding, redirects (FR-FT8, AC-FT8/9/20, T-FT1/2) | `RemoteUrlValidatorTest`, `FetchRemoteFileTest`, `RemoteFetchControllerTest` |
| Job, progress, retries (FR-FT9–12) | `FetchRemoteFileTest` |
| Permissions, rate limit (FR-FT18) | `ChunkControllerTest`, `MergeControllerTest`, `RemoteFetchControllerTest`, `ProviderTest` |
| Wings upload | `PanelWingsFileServiceTest` |
| Upload engine, checksums, retries, cancel | `sha256.spec.ts`, `base64.spec.ts`, `upload.spec.ts`, `ChunkedUploader.spec.tsx` |
| Fetch dialog, failure wording | `RemoteFetchDialog.spec.tsx`, `api.spec.ts` |
| Who sees which button | `FileTransferToolbar.spec.tsx`, `index.spec.tsx` |

## Known limits

- The Wings `files/write` endpoint has been tested against the Panel's own fake, not a real Wings.
- Two uploads of the same file name to the same folder replace each other; the dialog says so.
