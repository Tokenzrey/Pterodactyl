import {
    actionsColumn,
    Badge,
    Button,
    Card,
    CopyOnClick,
    Empty,
    EmptyContent,
    EmptyDescription,
    EmptyHeader,
    EmptyTitle,
    fromNow,
    httpErrorToHuman,
    Input,
    PageContentBlock,
    PageHeading,
    PanelLink,
    RowActionButton,
    RowActions,
    Table,
    type TableColumn,
} from '@pterodactyl/sdk';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Check, CircleAlert, RotateCw, Trash2, X } from 'lucide-react';
import { useEffect, useState } from 'react';
import { fetchOverview, fetchRecords, removeRecord, retryRecord, testConnection, type ConnectionResult, type RecordRow } from '../api';
import { Notice } from '../Notice';
import { errorAdvice, STATUS_META, STATUSES, type Status } from '../labels';

const PER_PAGE = 25;
const REFRESH_MS = 8000;

function Item({ ok, children }: { ok: boolean; children: React.ReactNode }) {
    return (
        <li className="sdm:flex sdm:items-center sdm:gap-2 sdm:text-sm">
            {ok ? <Check aria-hidden="true" className="sdm:size-4 sdm:text-success" /> : <X aria-hidden="true" className="sdm:size-4 sdm:text-destructive" />}
            <span>{children}</span>
            <span className="sdm:sr-only">{ok ? '(done)' : '(missing)'}</span>
        </li>
    );
}

/** Whether Cloudflare can be reached with what is saved, and the one-click proof of it. */
function SetupCard() {
    const overview = useQuery({ queryKey: ['subdomain-manager', 'overview'], queryFn: fetchOverview });
    const [result, setResult] = useState<ConnectionResult | null>(null);
    const test = useMutation({ mutationFn: testConnection, onSuccess: setResult });
    const setup = overview.data?.setup;
    const ready = Boolean(setup?.token && setup.domains > 0 && setup.target_ip);

    return (
        <Card title="Setup" className="sdm:mb-4">
            {setup ? (
                <>
                    <ul className="sdm:flex sdm:flex-col sdm:gap-1.5">
                        <Item ok={setup.token}>Cloudflare API token saved</Item>
                        <Item ok={setup.domains > 0}>{setup.domains > 0 ? `${setup.domains} domain${setup.domains === 1 ? '' : 's'} configured` : 'At least one domain configured'}</Item>
                        <Item ok={setup.target_ip}>Target IPv4 address set</Item>
                    </ul>
                    <p className="sdm:mt-3 sdm:text-sm sdm:text-foreground/80">
                        {ready ? 'Everything needed is saved. ' : 'Finish these in the extension settings. '}
                        <PanelLink destination={{ to: '/panel/extensions' }} className="sdm:underline">
                            Open extension settings
                        </PanelLink>
                    </p>
                    <div className="sdm:mt-3">
                        <Button color="grey" isSecondary size="small" onClick={() => test.mutate()} isLoading={test.isPending} disabled={!ready}>
                            Test Cloudflare connection
                        </Button>
                    </div>
                </>
            ) : overview.isError ? (
                <p className="sdm:text-sm">The setup status could not be loaded.</p>
            ) : (
                <p className="sdm:text-sm sdm:text-foreground/80">Loading…</p>
            )}

            {test.isError ? <p role="alert" className="sdm:mt-3 sdm:text-sm sdm:text-destructive">{httpErrorToHuman(test.error)}</p> : null}
            {result ? (
                <ul aria-label="Connection test results" className="sdm:mt-3 sdm:flex sdm:flex-col sdm:gap-1.5">
                    {result.results.map((item) => (
                        <li key={item.domain} className="sdm:flex sdm:items-start sdm:gap-2 sdm:text-sm">
                            {item.ok ? <Check aria-hidden="true" className="sdm:mt-0.5 sdm:size-4 sdm:text-success" /> : <CircleAlert aria-hidden="true" className="sdm:mt-0.5 sdm:size-4 sdm:text-destructive" />}
                            <span>
                                <code className="sdm:font-mono">{item.domain}</code>: {item.ok ? 'connected' : `could not connect. Cloudflare said: ${item.message ?? 'no answer'}`}
                            </span>
                        </li>
                    ))}
                </ul>
            ) : null}
        </Card>
    );
}

/** The admin overview of every subdomain: find one, see what is wrong with it, retry or remove it. */
export default function Subdomains() {
    const client = useQueryClient();
    const [page, setPage] = useState(1);
    const [status, setStatus] = useState<Status | undefined>();
    const [search, setSearch] = useState('');
    const [q, setQ] = useState('');
    const [confirming, setConfirming] = useState<RecordRow | null>(null);
    const [message, setMessage] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null);

    useEffect(() => {
        const timer = setTimeout(() => {
            setQ(search.trim());
            setPage(1);
        }, 300);

        return () => clearTimeout(timer);
    }, [search]);

    const overview = useQuery({ queryKey: ['subdomain-manager', 'overview'], queryFn: fetchOverview });
    const busy = (overview.data?.counts.pending ?? 0) + (overview.data?.counts.deleting ?? 0) > 0;
    const records = useQuery({
        queryKey: ['subdomain-manager', 'records', page, status ?? '', q],
        queryFn: () => fetchRecords({ page, status, q }),
        refetchInterval: busy ? REFRESH_MS : false,
        placeholderData: (previous) => previous,
    });
    useEffect(() => {
        if (busy) {
            const timer = setInterval(() => void client.invalidateQueries({ queryKey: ['subdomain-manager', 'overview'] }), REFRESH_MS);

            return () => clearInterval(timer);
        }
    }, [busy, client]);

    const refresh = () => client.invalidateQueries({ queryKey: ['subdomain-manager'] });
    const retry = useMutation({
        mutationFn: retryRecord,
        onSuccess: async () => {
            setMessage({ kind: 'ok', text: 'Retry queued. The status updates on its own.' });
            await refresh();
        },
        onError: (error) => setMessage({ kind: 'error', text: httpErrorToHuman(error) }),
    });
    const remove = useMutation({
        mutationFn: removeRecord,
        onSuccess: async () => {
            setConfirming(null);
            setMessage({ kind: 'ok', text: 'Removal queued. The DNS records are deleted at Cloudflare in the background.' });
            await refresh();
        },
        onError: (error) => setMessage({ kind: 'error', text: httpErrorToHuman(error) }),
    });

    const counts = overview.data?.counts;
    const rows = records.data?.rows ?? [];

    const columns: TableColumn<RecordRow>[] = [
        {
            id: 'address',
            label: 'Address',
            cell: (row) => (
                <CopyOnClick text={row.address}>
                    <code className="sdm:cursor-pointer sdm:whitespace-nowrap sdm:font-mono sdm:text-sm" title="Copy address">
                        {row.address}
                    </code>
                </CopyOnClick>
            ),
        },
        {
            id: 'server',
            label: 'Server',
            cell: (row) =>
                row.server ? (
                    <PanelLink destination={{ to: '/panel/servers/$id/details', params: { id: String(row.server.id) } }} className="sdm:underline">
                        {row.server.name}
                    </PanelLink>
                ) : (
                    <span className="sdm:text-foreground/80">Deleted server</span>
                ),
        },
        {
            id: 'status',
            label: 'Status',
            cell: (row) => {
                const meta = STATUS_META[row.status];
                const advice = errorAdvice(row.last_error);

                return (
                    <div className="sdm:flex sdm:flex-col sdm:items-start sdm:gap-1">
                        <Badge tone={meta.tone} variant="soft" className={meta.tone === 'neutral' || meta.tone === 'warning' ? 'sdm:text-foreground' : undefined}>
                            {meta.text}
                        </Badge>
                        {row.routing ? (
                            <span className="sdm:text-xs sdm:text-foreground/80">
                                {row.routing.state === 'ready' ? 'Routed by the router' : `Not routed: ${row.routing.reason ?? 'unknown reason'}`}
                            </span>
                        ) : null}
                        {row.last_error ? <span className="sdm:text-xs sdm:text-foreground/80">{row.last_error}</span> : null}
                        {advice ? <span className="sdm:text-xs">{advice}</span> : null}
                    </div>
                );
            },
        },
        { id: 'updated', label: 'Updated', cell: (row) => <span className="sdm:text-sm sdm:text-foreground/80">{row.updated_at ? fromNow(row.updated_at) : '—'}</span> },
        actionsColumn(2, (row) => (
            <RowActions>
                {row.status !== 'active' ? (
                    <RowActionButton aria-label={`Retry ${row.address}`} label="Retry now" icon={RotateCw} onClick={() => retry.mutate(row.id)} disabled={retry.isPending} />
                ) : null}
                <RowActionButton aria-label={`Remove ${row.address}`} label="Remove subdomain" icon={Trash2} danger onClick={() => setConfirming(row)} />
            </RowActions>
        )),
    ];

    return (
        <PageContentBlock title="Subdomains">
            <PageHeading title="Subdomains" description="The names given to game servers at Cloudflare. A server gets one in Admin → Servers, under Subdomain." />
            <SetupCard />

            {message ? (
                <div className="sdm:mb-3">
                    <Notice tone={message.kind === 'ok' ? 'success' : 'danger'} title={message.text} />
                </div>
            ) : null}

            {confirming ? (
                <div role="group" aria-label={`Remove ${confirming.address}?`} className="sdm:mb-3">
                    <Notice tone="warning" title={`Remove ${confirming.address}?`}>
                        The DNS records are deleted at Cloudflare.{' '}
                        {confirming.server
                            ? `${confirming.server.name} keeps running, but players can no longer join with this name.`
                            : 'The server it belonged to is already gone, so nothing else changes.'}
                        <div className="sdm:mt-3 sdm:flex sdm:gap-2">
                            <Button color="red" size="small" onClick={() => remove.mutate(confirming.id)} isLoading={remove.isPending}>
                                Yes, remove
                            </Button>
                            <Button color="grey" isSecondary size="small" onClick={() => setConfirming(null)} disabled={remove.isPending}>
                                Keep it
                            </Button>
                        </div>
                    </Notice>
                </div>
            ) : null}

            <div className="sdm:mb-3 sdm:flex sdm:flex-col sdm:gap-3 sdm:sm:flex-row sdm:sm:items-center sdm:sm:justify-between">
                <div role="group" aria-label="Filter by status" className="sdm:flex sdm:flex-wrap sdm:gap-2">
                    {[undefined, ...STATUSES].map((value) => {
                        const count = value ? counts?.[value] : counts?.total;

                        return (
                            <Button
                                key={value ?? 'all'}
                                size="small"
                                color={status === value ? 'primary' : 'grey'}
                                isSecondary={status !== value}
                                aria-pressed={status === value}
                                onClick={() => {
                                    setStatus(value);
                                    setPage(1);
                                }}
                            >
                                {value ? STATUS_META[value].text : 'All'}
                                {count !== undefined ? ` (${count})` : ''}
                            </Button>
                        );
                    })}
                </div>
                <div className="sdm:sm:w-64">
                    <Input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search addresses" aria-label="Search addresses" maxLength={100} />
                </div>
            </div>

            {records.isError ? (
                <Notice tone="danger" title="The subdomains could not be loaded">
                    Reload the page to try again.
                </Notice>
            ) : (
                <div className="sdm:overflow-x-auto">
                    <Table
                        rows={rows}
                        columns={columns}
                        keyOf={(row) => String(row.id)}
                        isFetching={records.isFetching}
                        pagination={{ page: records.data?.page ?? 1, perPage: PER_PAGE, total: records.data?.total ?? 0, count: rows.length, itemLabel: 'subdomains', onPageSelect: setPage }}
                        emptyState={
                            status || q ? (
                                <Empty>
                                    <EmptyHeader>
                                        <EmptyTitle>Nothing matches</EmptyTitle>
                                        <EmptyDescription>Try another status or search.</EmptyDescription>
                                    </EmptyHeader>
                                    <EmptyContent>
                                        <Button
                                            color="grey"
                                            isSecondary
                                            size="small"
                                            onClick={() => {
                                                setStatus(undefined);
                                                setSearch('');
                                            }}
                                        >
                                            Clear filters
                                        </Button>
                                    </EmptyContent>
                                </Empty>
                            ) : (
                                <Empty>
                                    <EmptyHeader>
                                        <EmptyTitle>No subdomains yet</EmptyTitle>
                                        <EmptyDescription>Open a server in Admin → Servers and enter a label under Subdomain.</EmptyDescription>
                                    </EmptyHeader>
                                </Empty>
                            )
                        }
                    />
                </div>
            )}
        </PageContentBlock>
    );
}
