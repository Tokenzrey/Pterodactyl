import { Card, Empty, EmptyDescription, EmptyHeader, EmptyTitle, ServerContentBlock, Spinner, useCurrentServerRequired, useServerPermission } from '@pterodactyl/sdk';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { ActionConfirm } from './ActionConfirm';
import { ACTIONS } from './actions';
import { describeError, runAction, type Message, type PlayerAction } from './api';
import { Notice } from './Notice';
import { PlayerRow, type Abilities } from './PlayerRow';
import { countText, usePlayers } from './usePlayers';

/** The players of the current server, with kick, ban, OP and de-OP for those allowed. Every action asks first. */
export default function PlayerScreen() {
    const uuid = useCurrentServerRequired().attributes.uuid;
    const client = useQueryClient();
    const players = usePlayers(uuid);
    const can: Abilities = {
        kick: useServerPermission('ext.player-manager.kick'),
        ban: useServerPermission('ext.player-manager.ban'),
        op: useServerPermission('ext.player-manager.op'),
        deop: useServerPermission('ext.player-manager.deop'),
    };

    const [asking, setAsking] = useState<{ name: string; action: PlayerAction } | null>(null);
    const [result, setResult] = useState<({ tone: 'success' } & { title: string }) | ({ tone: 'danger' } & Message) | null>(null);

    const act = useMutation({
        mutationFn: ({ name, action, reason }: { name: string; action: PlayerAction; reason: string }) => runAction(uuid, name, action, reason),
        onSuccess: async (_data, { name, action }) => {
            setAsking(null);
            setResult({ tone: 'success', title: ACTIONS[action].done(name) });
            await client.invalidateQueries({ queryKey: ['player-manager', 'players', uuid] });
        },
        onError: (error) => {
            setAsking(null);
            setResult({ tone: 'danger', ...describeError(error) });
        },
    });

    return (
        <ServerContentBlock title="Players">
            {result ? (
                <div className="plm:mb-4">
                    {result.tone === 'success' ? <Notice tone="success" title={result.title} /> : <Notice tone="danger" title={result.title}>{result.body}</Notice>}
                </div>
            ) : null}

            {players.isPending ? (
                <div role="status" className="plm:flex plm:items-center plm:gap-3 plm:text-sm plm:text-foreground/80">
                    <Spinner size="small" />
                    Loading players…
                </div>
            ) : null}

            {players.isError ? (
                <Notice tone="danger" title={describeError(players.error).title}>
                    {describeError(players.error).body} This page keeps trying on its own.
                </Notice>
            ) : null}

            {players.data && players.data.list.players.length === 0 ? (
                <Empty>
                    <EmptyHeader>
                        <EmptyTitle>Nobody is online</EmptyTitle>
                        <EmptyDescription>Players show up here as soon as they join the server.</EmptyDescription>
                    </EmptyHeader>
                </Empty>
            ) : null}

            {players.data && players.data.list.players.length > 0 ? (
                <Card title={countText(players.data.list.online_count, players.data.list.max_count)}>
                    <ul className="plm:divide-y plm:divide-border">
                        {players.data.list.players.map((player, index) => (
                            <PlayerRow key={`${player.name}-${index}`} player={player} can={can} busy={act.isPending} onAsk={(action) => { setResult(null); setAsking({ name: player.name, action }); }}>
                                {asking?.name === player.name && asking.action ? (
                                    <ActionConfirm
                                        name={player.name}
                                        action={asking.action}
                                        busy={act.isPending}
                                        onConfirm={(reason) => act.mutate({ name: player.name, action: asking.action, reason })}
                                        onCancel={() => setAsking(null)}
                                    />
                                ) : null}
                            </PlayerRow>
                        ))}
                    </ul>
                </Card>
            ) : null}
        </ServerContentBlock>
    );
}
