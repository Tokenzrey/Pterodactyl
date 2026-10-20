import { Button, Card, Empty, EmptyDescription, EmptyHeader, EmptyTitle, httpErrorToHuman, LinkButton, PageContentBlock, PageHeading, Spinner } from '@pterodactyl/sdk';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { disconnectAccount, fetchAccounts, type AccountProvider } from '../api';
import type { ProviderId } from '../config';
import { ProviderIcon } from '../icons';
import { Notice } from '../Notice';
import { linkPath } from '../messages';
import { ResultBanner } from '../ResultBanner';

const QUERY_KEY = ['oauth-login', 'accounts'];

const DATE = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric' });

/** "Connected Mar 12, 2026", with a note when an administrator has switched this sign-in method off. */
function describe(provider: AccountProvider): string {
    if (!provider.linked) {
        return 'Not connected';
    }
    const since = provider.linked_at ? `Connected ${DATE.format(new Date(provider.linked_at))}` : 'Connected';

    return provider.enabled ? since : `${since}. Signing in with it is turned off by an administrator.`;
}

function Row({ provider, confirming, onAsk, onCancel, onConfirm, busy }: {
    provider: AccountProvider;
    confirming: boolean;
    onAsk: () => void;
    onCancel: () => void;
    onConfirm: () => void;
    busy: boolean;
}) {
    return (
        <li className="olg:flex olg:flex-col olg:gap-3 olg:py-4 olg:first:pt-0 olg:last:pb-0">
            <div className="olg:flex olg:items-center olg:gap-3">
                <ProviderIcon id={provider.id} className="olg:size-6 olg:shrink-0" />
                <div className="olg:min-w-0 olg:flex-1">
                    <p className="olg:font-medium">{provider.label}</p>
                    <p className="olg:text-sm olg:text-foreground/80">{describe(provider)}</p>
                </div>
                {provider.linked ? (
                    <Button color="grey" isSecondary size="small" onClick={onAsk} aria-label={`Disconnect ${provider.label}`} disabled={busy || confirming}>
                        Disconnect
                    </Button>
                ) : (
                    <LinkButton href={linkPath(provider.id)} color="primary" size="small" aria-label={`Connect ${provider.label}`}>
                        Connect
                    </LinkButton>
                )}
            </div>

            {confirming ? (
                <div role="group" aria-label={`Disconnect ${provider.label}?`} className="olg:rounded-md olg:border olg:border-border olg:bg-muted olg:p-3 olg:text-sm">
                    <p>
                        You will no longer be able to sign in with {provider.label}. If you have never set a password, set one in your account settings first, or you will be
                        locked out.
                    </p>
                    <div className="olg:mt-3 olg:flex olg:gap-2">
                        <Button color="red" size="small" onClick={onConfirm} isLoading={busy}>
                            Yes, disconnect
                        </Button>
                        <Button color="grey" isSecondary size="small" onClick={onCancel} disabled={busy}>
                            Keep connected
                        </Button>
                    </div>
                </div>
            ) : null}
        </li>
    );
}

/** The "Connected accounts" page of the signed-in user: connect a provider, or disconnect one. */
export default function ConnectedAccounts() {
    const client = useQueryClient();
    const accounts = useQuery({ queryKey: QUERY_KEY, queryFn: fetchAccounts, staleTime: 15_000 });
    const [confirming, setConfirming] = useState<ProviderId | null>(null);
    const [failure, setFailure] = useState<string | null>(null);

    const disconnect = useMutation({
        mutationFn: disconnectAccount,
        onSuccess: async () => {
            setConfirming(null);
            setFailure(null);
            await client.invalidateQueries({ queryKey: QUERY_KEY });
        },
        onError: (error) => setFailure(httpErrorToHuman(error)),
    });

    return (
        <PageContentBlock title="Connected accounts">
            <PageHeading title="Connected accounts" description="Sign in with one click using an account you already have. The provider shares your name and verified email address, never your password." />
            <ResultBanner context="account" />

            {accounts.isPending ? <Spinner centered size="large" /> : null}
            {accounts.isError ? (
                <Empty>
                    <EmptyHeader>
                        <EmptyTitle>Could not load your connected accounts</EmptyTitle>
                        <EmptyDescription>Reload the page. If this keeps happening, tell an administrator.</EmptyDescription>
                    </EmptyHeader>
                </Empty>
            ) : null}
            {accounts.data && accounts.data.length === 0 ? (
                <Empty>
                    <EmptyHeader>
                        <EmptyTitle>No sign-in providers are set up</EmptyTitle>
                        <EmptyDescription>An administrator can turn on Discord, GitHub or Google in Admin → Extensions → OAuth Login.</EmptyDescription>
                    </EmptyHeader>
                </Empty>
            ) : null}
            {failure ? (
                <div className="olg:mb-4">
                    <Notice tone="danger" title="Could not disconnect that account">
                        {failure} Nothing was changed. Try again in a moment.
                    </Notice>
                </div>
            ) : null}

            {accounts.data && accounts.data.length > 0 ? (
                <Card title="Sign-in providers">
                    <ul className="olg:divide-y olg:divide-border">
                        {accounts.data.map((provider) => (
                            <Row
                                key={provider.id}
                                provider={provider}
                                confirming={confirming === provider.id}
                                busy={disconnect.isPending && confirming === provider.id}
                                onAsk={() => {
                                    setFailure(null);
                                    setConfirming(provider.id);
                                }}
                                onCancel={() => setConfirming(null)}
                                onConfirm={() => disconnect.mutate(provider.id)}
                            />
                        ))}
                    </ul>
                </Card>
            ) : null}
        </PageContentBlock>
    );
}
