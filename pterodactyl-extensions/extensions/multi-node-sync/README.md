# Multi-Node Sync

Migrate server files between Pterodactyl nodes and generate S3 presigned URLs for direct browser transfers.

## Installation

```bash
p:extension:install multi-node-sync --enable
```

## Configuration

Go to Admin → Extensions → Multi-Node Sync → Settings:
- **S3 endpoint**: HTTPS endpoint for your S3-compatible storage (AWS, MinIO, Wasabi, etc.)
- **S3 region**: AWS region (e.g., us-east-1)
- **S3 bucket**: Bucket name
- **S3 access key** (secret, encrypted): Access key ID
- **S3 secret key** (secret, encrypted): Secret access key
- **Allow HTTP S3**: Allow non-HTTPS endpoints (for local MinIO, not recommended for production)
- **Presigned URL TTL** (5–60 minutes, default 15): How long presigned URLs remain valid
- **Max migration size** (100–102400 MB, default 10240): Maximum archive size for migrations

## Usage

### Server Migration
1. Navigate to Admin → Migrations
2. Select a source server, target node, and a free allocation on the target node
3. Type the server name to confirm
4. The extension delegates to the Panel's built-in server transfer mechanism (`POST /api/admin/servers/{id}/transfer`), which handles archiving on the source node, transferring to the target node, and updating the server's `node_id` — all via Wings daemon-to-daemon communication

The job sends an internal sub-request to the Panel's Admin API transfer endpoint (no external HTTP call or API key needed, since the extension runs inside the Panel's Laravel app). It then polls the server's status until the transfer completes or fails.

### S3 Transfer
1. Navigate to Admin → S3 Transfer
2. Choose upload or download method
3. Enter an object key
4. Generate a presigned URL for direct browser-to-S3 transfer

## Permissions

- `ext.multi-node-sync.migrate` — required for server migrations
- `ext.multi-node-sync.s3-presign` — required for S3 presigned URL generation

## Limitations

- S3 credentials are stored encrypted and never sent to frontend
- SigV4 signing is implemented manually (no AWS SDK dependency)
- Server migration uses the Panel's built-in transfer API; the extension does not directly call Wings file endpoints for migration
- Server must be stopped before migration
- Cannot migrate to the same node
- Target allocation must be free (not assigned to another server) and must belong to the target node
- The job runs the transfer as a root administrator. If none exists the migration fails with `no_admin`.
- The job's own timeout is 3700 seconds, so the polling wait is not cut off by the worker's default limit.
- The transfer polling interval is 5 seconds with a maximum wait of 1 hour

## Prerequisites

- S3-compatible storage (AWS S3, MinIO, Wasabi, etc.) with access key and secret key
- Two or more Pterodactyl nodes with Wings daemons
- Panel 2.0.0-beta.2 or later

## Testing

```bash
tools/pest.sh multi-node-sync    # Pest integration + unit tests
tools/build.sh multi-node-sync   # Vitest + typecheck + build
```

## Traceability

| Requirement | Test |
|---|---|
| FR-MN2 (presigned URL) | `S3ControllerTest > generates presigned URL` |
| FR-MN5 (migration create) | `MigrationControllerTest > creates migration` |
| FR-MN15 (progress stages) | `MigrateServerFilesTest > completes the migration` |
| FR-MN18 (error codes) | `MigrateServerFilesTest > target_unavailable, source_unavailable` |
| AC-MN1 (presign success) | `S3ControllerTest > generates presigned URL` |
| AC-MN2 (S3 not configured) | `S3ControllerTest > returns 503` |
| AC-MN3 (path traversal) | `S3ControllerTest > rejects path traversal` |
| AC-MN7 (name confirmation) | `MigrationControllerTest > rejects wrong server name` |
| AC-MN20 (SigV4 correct) | `SigV4SignerTest > generates URL with all required parameters` |
| T-MN4 (non-admin access) | `S3ControllerTest > rejects non-admin`, `MigrationControllerTest > rejects non-admin` |
| T-MN5 (destructive migration) | `MigrationControllerTest > AC-MN7`; the Panel's transfer moves the server, so no option decides what happens to the source |
| T-MN6 (path traversal) | `PathValidatorTest`, `S3ControllerTest > AC-MN3` |
| T-X8 (no secret leak) | `S3ConfigTest > does not leak secret`, `SettingsTest > encrypts S3 credentials` |
