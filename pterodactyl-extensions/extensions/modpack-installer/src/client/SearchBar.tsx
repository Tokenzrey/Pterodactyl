import { Button, Input, Label } from '@pterodactyl/sdk';
import { useEffect, useId, useRef, useState } from 'react';
import { isGameVersion, type Loader, type SearchCriteria, type ServerDefaults, type Source } from './api';

/** How long typing must pause before a search goes out (FR-MI15). */
export const DEBOUNCE_MS = 500;

/** Where the form starts: the server's saved defaults, or the built-in ones. */
export interface SearchStart {
    source: Source;
    gameVersion: string;
    loader: Loader | '';
}

const SELECT =
    'mki:block mki:h-9 mki:w-full mki:rounded-md mki:border mki:border-border mki:bg-transparent mki:px-3 mki:text-sm mki:text-foreground mki:focus-visible:outline-2 mki:focus-visible:outline-offset-2 mki:focus-visible:outline-primary';

/**
 * The search form. It does not search by itself: after typing stops for DEBOUNCE_MS it reports what to look for, or null
 * when there is nothing worth asking (no query, or a version the Panel would refuse). It can also save its choices as the
 * server's defaults, which the next visit starts from.
 */
export function SearchBar({ onCriteria, start, onSaveDefaults, savingDefaults = false }: {
    onCriteria: (criteria: SearchCriteria | null) => void;
    start: SearchStart;
    onSaveDefaults?: (values: ServerDefaults) => void;
    savingDefaults?: boolean;
}) {
    const sourceId = useId();
    const queryId = useId();
    const versionId = useId();
    const versionHelpId = useId();
    const loaderId = useId();
    const [source, setSource] = useState<Source>(start.source);
    const [query, setQuery] = useState('');
    const [gameVersion, setGameVersion] = useState(start.gameVersion);
    const [loader, setLoader] = useState<Loader | ''>(start.loader);
    const latest = useRef(onCriteria);
    latest.current = onCriteria;

    const versionOk = isGameVersion(gameVersion.trim());

    useEffect(() => {
        const text = query.trim();
        const timer = setTimeout(() => {
            latest.current(
                text === '' || !versionOk
                    ? null
                    : { source, query: text, ...(gameVersion.trim() !== '' ? { game_version: gameVersion.trim() } : {}), ...(loader !== '' ? { loader } : {}) },
            );
        }, DEBOUNCE_MS);

        return () => clearTimeout(timer);
    }, [source, query, gameVersion, loader, versionOk]);

    return (
        <form role="search" className="mki:grid mki:gap-4 mki:sm:grid-cols-2 mki:lg:grid-cols-[10rem_1fr_10rem_10rem]" onSubmit={(event) => event.preventDefault()}>
            <div>
                <Label htmlFor={sourceId}>Source</Label>
                <select id={sourceId} className={SELECT} value={source} onChange={(event) => setSource(event.target.value as Source)}>
                    <option value="curseforge">CurseForge</option>
                    <option value="modrinth">Modrinth</option>
                </select>
            </div>
            <div className="mki:sm:col-span-2 mki:lg:col-span-1">
                <Label htmlFor={queryId}>Search modpacks</Label>
                <Input id={queryId} type="search" value={query} onChange={(event) => setQuery(event.target.value)} maxLength={100} autoComplete="off" spellCheck={false} placeholder="All the Mods" />
            </div>
            <div>
                <Label htmlFor={versionId}>Minecraft version</Label>
                <Input
                    id={versionId}
                    value={gameVersion}
                    onChange={(event) => setGameVersion(event.target.value)}
                    maxLength={20}
                    autoComplete="off"
                    spellCheck={false}
                    placeholder="1.20.1"
                    aria-invalid={versionOk ? undefined : true}
                    aria-describedby={versionHelpId}
                />
                <p id={versionHelpId} className={`mki:mt-1 mki:text-xs ${versionOk ? 'mki:text-foreground/80' : 'mki:text-destructive'}`}>
                    {versionOk ? 'Optional.' : 'Use only letters, digits, dots and hyphens.'}
                </p>
            </div>
            <div>
                <Label htmlFor={loaderId}>Mod loader</Label>
                <select id={loaderId} className={SELECT} value={loader} onChange={(event) => setLoader(event.target.value as Loader | '')}>
                    <option value="">Any</option>
                    <option value="forge">Forge</option>
                    <option value="neoforge">NeoForge</option>
                    <option value="fabric">Fabric</option>
                    <option value="quilt">Quilt</option>
                </select>
                {source === 'curseforge' && loader !== '' && gameVersion.trim() === '' ? <p className="mki:mt-1 mki:text-xs mki:text-foreground/80">CurseForge applies a loader only together with a Minecraft version.</p> : null}
            </div>
            {onSaveDefaults ? (
                <div className="mki:flex mki:items-end mki:justify-end mki:sm:col-span-2 mki:lg:col-span-4">
                    <Button
                        type="button"
                        color="grey"
                        isSecondary
                        size="small"
                        disabled={!versionOk}
                        isLoading={savingDefaults}
                        onClick={() => onSaveDefaults({ default_source: source, default_game_version: gameVersion.trim(), default_loader: loader })}
                    >
                        Save these as the defaults for this server
                    </Button>
                </div>
            ) : null}
        </form>
    );
}
