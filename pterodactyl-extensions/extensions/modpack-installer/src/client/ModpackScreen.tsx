import { Button, Empty, EmptyDescription, EmptyHeader, EmptyTitle, ServerContentBlock, Spinner, useCurrentServerRequired } from '@pterodactyl/sdk';
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback, useState } from 'react';
import { describeError, FALLBACK_DEFAULTS, getServerDefaults, PAGE_SIZE, saveServerDefaults, searchModpacks, type ModpackFile, type ModpackResult, type SearchCriteria, type ServerDefaults } from './api';
import { InstallDialog } from './InstallDialog';
import { InstallProgress } from './InstallProgress';
import { Notice } from './Notice';
import { ResultCard } from './ResultCard';
import { SearchBar } from './SearchBar';

/** Search CurseForge or Modrinth for a modpack and install its server pack on this server. */
export default function ModpackScreen() {
    const serverUuid = useCurrentServerRequired().attributes.uuid;
    const queryClient = useQueryClient();
    const [criteria, setCriteria] = useState<SearchCriteria | null>(null);
    const [page, setPage] = useState(0);
    const [choice, setChoice] = useState<{ result: ModpackResult; file: ModpackFile } | null>(null);
    const [job, setJob] = useState<{ id: string; name: string } | null>(null);
    const [saved, setSaved] = useState(false);

    const defaultsKey = ['modpack-installer', 'defaults', serverUuid];
    const defaults = useQuery({
        queryKey: defaultsKey,
        queryFn: ({ signal }) => getServerDefaults(serverUuid, signal),
        staleTime: Infinity,
        retry: false,
    });

    const save = useMutation({
        mutationFn: (values: ServerDefaults) => saveServerDefaults(serverUuid, values),
        onMutate: () => setSaved(false),
        onSuccess: (next) => {
            queryClient.setQueryData(defaultsKey, next);
            setSaved(true);
        },
    });

    // A new search starts at the first page. React Query cancels the search it replaces (FR-MI15).
    const onCriteria = useCallback((next: SearchCriteria | null) => {
        setCriteria(next);
        setPage(0);
    }, []);

    const search = useQuery({
        queryKey: ['modpack-installer', 'search', serverUuid, criteria, page],
        queryFn: ({ signal }) => searchModpacks(serverUuid, criteria as SearchCriteria, page, signal),
        enabled: criteria !== null,
        placeholderData: keepPreviousData,
        staleTime: 30_000,
        retry: false,
    });

    if (job !== null) {
        return (
            <ServerContentBlock title="Modpacks">
                <InstallProgress jobId={job.id} serverUuid={serverUuid} name={job.name} onDone={() => setJob(null)} />
            </ServerContentBlock>
        );
    }

    // The form starts from the saved defaults, so it waits for them. If they cannot be read, the built-in ones are used.
    if (defaults.isPending) {
        return (
            <ServerContentBlock title="Modpacks">
                <div role="status" className="mki:flex mki:items-center mki:gap-3 mki:text-sm mki:text-foreground/80">
                    <Spinner size="small" />
                    Loading…
                </div>
            </ServerContentBlock>
        );
    }

    const start = defaults.data ?? FALLBACK_DEFAULTS;
    const data = criteria === null ? undefined : search.data;
    const pages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1;

    return (
        <ServerContentBlock title="Modpacks">
            <div className="mki:flex mki:flex-col mki:gap-6">
                <SearchBar
                    onCriteria={onCriteria}
                    start={{ source: start.default_source, gameVersion: start.default_game_version, loader: start.default_loader }}
                    onSaveDefaults={(values) => save.mutate(values)}
                    savingDefaults={save.isPending}
                />

                {saved ? <Notice tone="success" title="Saved as this server's defaults" /> : null}
                {save.isError ? (
                    <Notice tone="danger" title={describeError(save.error).title}>
                        {describeError(save.error).body}
                    </Notice>
                ) : null}

                {criteria?.source === 'modrinth' ? (
                    <Notice tone="info" title="Modrinth packs cannot be installed here">
                        Modrinth has no server packs, only packs for players. Search CurseForge to install one, or follow the pack&rsquo;s own instructions for running a server.
                    </Notice>
                ) : null}

                {criteria === null ? (
                    <Empty>
                        <EmptyHeader>
                            <EmptyTitle>Search for a modpack</EmptyTitle>
                            <EmptyDescription>Type a name above. Results appear when you stop typing.</EmptyDescription>
                        </EmptyHeader>
                    </Empty>
                ) : null}

                {criteria !== null && search.isPending ? (
                    <div role="status" className="mki:flex mki:items-center mki:gap-3 mki:text-sm mki:text-foreground/80">
                        <Spinner size="small" />
                        Searching…
                    </div>
                ) : null}

                {criteria !== null && search.isError ? (
                    <Notice tone="danger" title={describeError(search.error).title}>
                        <p>{describeError(search.error).body}</p>
                        <div className="mki:mt-3">
                            <Button type="button" color="grey" isSecondary size="small" onClick={() => void search.refetch()} isLoading={search.isFetching}>
                                Try again
                            </Button>
                        </div>
                    </Notice>
                ) : null}

                {data && data.results.length === 0 ? (
                    <Empty>
                        <EmptyHeader>
                            <EmptyTitle>No modpacks found</EmptyTitle>
                            <EmptyDescription>Try another name, or take away the version or loader.</EmptyDescription>
                        </EmptyHeader>
                    </Empty>
                ) : null}

                {data && data.results.length > 0 ? (
                    <section aria-label="Search results" aria-busy={search.isFetching} className={search.isFetching ? 'mki:opacity-60' : undefined}>
                        <ul className="mki:grid mki:gap-4">
                            {data.results.map((result) => (
                                <ResultCard key={`${result.source}-${result.project_id}`} result={result} busy={choice !== null} onInstall={(picked, file) => setChoice({ result: picked, file })} />
                            ))}
                        </ul>

                        {pages > 1 ? (
                            <nav aria-label="Pages" className="mki:mt-4 mki:flex mki:items-center mki:justify-between">
                                <Button type="button" color="grey" isSecondary size="small" disabled={page === 0 || search.isFetching} onClick={() => setPage(page - 1)}>
                                    Previous
                                </Button>
                                <span className="mki:text-sm">
                                    Page {page + 1} of {pages}
                                </span>
                                <Button type="button" color="grey" isSecondary size="small" disabled={page + 1 >= pages || search.isFetching} onClick={() => setPage(page + 1)}>
                                    Next
                                </Button>
                            </nav>
                        ) : null}
                    </section>
                ) : null}
            </div>

            {choice !== null ? (
                <InstallDialog
                    serverUuid={serverUuid}
                    result={choice.result}
                    file={choice.file}
                    onClose={() => setChoice(null)}
                    onStarted={(id) => {
                        setJob({ id, name: choice.result.name });
                        setChoice(null);
                    }}
                />
            ) : null}
        </ServerContentBlock>
    );
}
