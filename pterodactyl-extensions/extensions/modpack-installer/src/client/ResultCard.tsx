import { Badge, Button } from '@pterodactyl/sdk';
import { formatSize, type ModpackFile, type ModpackResult } from './api';

/** One project: what it is, and the files it offers, each with a button if it is a server pack. */
export function ResultCard({ result, busy, onInstall }: { result: ModpackResult; busy: boolean; onInstall: (result: ModpackResult, file: ModpackFile) => void }) {
    return (
        <li className="mki:flex mki:gap-4 mki:rounded-md mki:border mki:border-border mki:p-4">
            {result.icon_url ? (
                <img src={result.icon_url} alt="" loading="lazy" referrerPolicy="no-referrer" className="mki:size-12 mki:shrink-0 mki:rounded mki:object-cover" />
            ) : (
                <div aria-hidden="true" className="mki:size-12 mki:shrink-0 mki:rounded mki:bg-muted" />
            )}

            <div className="mki:min-w-0 mki:flex-1">
                <h3 className="mki:font-medium">{result.name}</h3>
                {result.summary !== '' ? <p className="mki:mt-1 mki:line-clamp-2 mki:text-sm mki:text-foreground/80">{result.summary}</p> : null}
                <p className="mki:mt-1 mki:text-xs mki:text-foreground/80">{result.downloads.toLocaleString('en-US')} downloads</p>

                {result.latest_files.length > 0 ? (
                    <ul className="mki:mt-3 mki:divide-y mki:divide-border">
                        {result.latest_files.map((file) => (
                            <li key={`${file.file_id}-${file.name}`} className="mki:flex mki:flex-wrap mki:items-center mki:gap-x-3 mki:gap-y-2 mki:py-2">
                                <span className="mki:min-w-0 mki:flex-1 mki:break-all mki:text-sm">{file.name}</span>
                                {file.game_version ? <Badge size="sm">{file.game_version}</Badge> : null}
                                {file.loader ? <Badge size="sm">{file.loader}</Badge> : null}
                                {formatSize(file.file_size_mb) ? <span className="mki:text-xs mki:text-foreground/80">{formatSize(file.file_size_mb)}</span> : null}
                                {file.is_server_pack ? (
                                    <Button type="button" size="small" disabled={busy} onClick={() => onInstall(result, file)} aria-label={`Install the server pack of ${file.name}, from ${result.name}`}>
                                        Install server pack
                                    </Button>
                                ) : (
                                    <span className="mki:text-xs mki:text-foreground/80">No server pack</span>
                                )}
                            </li>
                        ))}
                    </ul>
                ) : (
                    <p className="mki:mt-3 mki:text-sm mki:text-foreground/80">{result.source === 'modrinth' ? 'Modrinth has no server packs to install.' : 'No files are listed for this pack.'}</p>
                )}
            </div>
        </li>
    );
}
