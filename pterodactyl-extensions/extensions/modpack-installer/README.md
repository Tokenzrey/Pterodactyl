# Modpack Installer

Search CurseForge for a modpack and install its **server pack** on a Pterodactyl server. The Panel downloads the pack, hands it to the server through Wings, has Wings extract it, and removes the launch scripts that clash with the egg's own.

## Installation

```bash
p:extension:install modpack-installer --enable
```

## Settings

Admin → Extensions → Modpack Installer:

| Setting | Range (default) | Meaning |
|---|---|---|
| API key | up to 256 characters | CurseForge API key (console.curseforge.com). Stored encrypted; the settings page only ever shows `********`. Without it CurseForge cannot be searched. |
| Max download size | 10–4096 MB (512) | Larger packs are refused before and while downloading. |
| Search cache | 0–300 s (60) | Identical searches within this time reuse one answer. 0 turns the cache off. |
| Extra sanitized files | up to 20 names | File names, no paths, removed after extraction in addition to `start.sh`, `run.bat`, `user_jvm_args.txt`, `start.bat`, `ServerStart.bat`. |

## Permission

`ext.modpack-installer.install` — search and install. The server's owner has it; for a subuser, grant it in the permission editor. Both routes check it again on the Panel.

## How it works

1. **Search** (`GET …/extensions/modpack-installer/search`): `source`, `query`, optional `game_version`, `loader`, `page`. For CurseForge, a client file is offered as the server pack it points to (`serverPackFileId`); a file that is itself a server pack is offered as it is. 30 requests a minute.
2. **Install** (`POST …/install`): the browser sends `source`, `project_id`, `file_id` and an optional `target_directory` — nothing else. The Panel asks CurseForge for that file, refuses anything that is not a server pack, and answers `202 {job_id}`. The id is a progress record that the page follows with `useExtensionJobProgress`.
3. **Job**: looks the file up again, downloads it to a private directory under `storage/app/extensions/modpack-installer/tmp`, checks the SHA-1 CurseForge gave, uploads it with `files/write`, extracts with `files/decompress`, deletes the archive, removes the launch scripts found in the folder, and reports `0–50 % downloading`, `50–80 uploading`, `80–95 extracting`, `95–99 sanitizing`, `100 completed`.
4. A failure is one fixed code (`source_unavailable`, `file_not_found`, `not_server_pack`, `download_failed`, `download_too_large`, `upload_failed`, `extract_failed`, `sanitize_failed`, `disk_full`) that the page puts into words. Only a failure that may not repeat (a node or CDN that did not answer) is tried again, up to three times.
5. `modpack-installer:cleanup` runs every 30 minutes: it removes archives older than two hours and finished install rows older than 30 days.

## Server defaults

Each server keeps what its search opens with: source, Minecraft version and mod loader. The form starts from them, and "Save these as the defaults for this server" stores what is on the form.

- `GET …/extensions/modpack-installer/defaults` and `PUT …/defaults` (same permission as installing: `ext.modpack-installer.install`).
- Stored per server, never in the global settings, so the admin settings form does not show them.
- Only the server's own defaults change; another server's are untouched.
- An unknown source, loader or version is refused with 422 and nothing is saved.

## Security

- **The browser decides nothing about the download.** No address, key or "is a server pack" flag is accepted from it. The address comes from CurseForge's own answer.
- **SSRF.** A download is followed only over `https` on `forgecdn.net` and `curseforge.com` (and their subdomains), with at most three redirects, each checked the same way. API addresses are constants.
- **Paths.** The folder is checked with `\A…\z`: no `..`, no leading `/`, no `//`. File names to delete are plain names only.
- **Size.** Checked from CurseForge's description, from `Content-Length`, and while streaming; a partial file is removed. A stalled CDN is cut off.
- **Secrets.** The key is never sent to the browser or logged. Logs carry the server, source, project id and a code, never an address.
- **One install at a time** per pack and server (409 `install_in_progress`); a lost install stops blocking after an hour.

## Limits

- **Modrinth can be searched, not installed from.** Modrinth has no server packs: its modpacks are a client format (`.mrpack`). The page says so.
- A pack whose author keeps it on the CurseForge site only cannot be downloaded (`download_not_allowed`).
- The Modrinth API is v2; v1, which the original plan named, has been retired.
- The default source is `curseforge`, not `modrinth` as the plan first said: only CurseForge can install, so the form opens on the source that works.
- The Wings calls follow the Panel's own file manager and are tested against the Panel's fake, not against a real node.

## Testing

```bash
tools/pest.sh modpack-installer    # backend: unit + integration
tools/build.sh modpack-installer   # typecheck + Vitest + build + prefixed-class check
```
