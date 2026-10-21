import { Badge, Button } from '@pterodactyl/sdk';
import type { ReactNode } from 'react';
import { ACTIONS, VALID_NAME } from './actions';
import type { Player, PlayerAction } from './api';
import { PlayerAvatar } from './PlayerAvatar';

export type Abilities = Record<PlayerAction, boolean>;

/** The actions this player can be given: each needs its permission, and OP shows only the direction that can apply. */
function available(player: Player, can: Abilities): PlayerAction[] {
    if (!VALID_NAME.test(player.name)) {
        return [];
    }

    const actions: PlayerAction[] = [];
    if (can.kick) actions.push('kick');
    if (can.ban) actions.push('ban');
    if (can.op && player.is_op !== true) actions.push('op');
    if (can.deop && player.is_op !== false) actions.push('deop');

    return actions;
}

/** One player: avatar, name, OP badge, ping, and the buttons the user may press. The confirm panel goes below. */
export function PlayerRow({ player, can, busy, onAsk, children }: {
    player: Player;
    can: Abilities;
    busy: boolean;
    onAsk: (action: PlayerAction) => void;
    children?: ReactNode;
}) {
    const name = player.name || 'Unknown player';

    return (
        <li className="plm:py-3 plm:first:pt-0 plm:last:pb-0">
            <div className="plm:flex plm:flex-wrap plm:items-center plm:gap-3">
                <PlayerAvatar name={name} uuid={player.uuid} />
                <div className="plm:flex plm:min-w-0 plm:flex-1 plm:items-center plm:gap-2">
                    <span className="plm:truncate plm:font-medium">{name}</span>
                    {player.is_op === true ? <Badge tone="neutral" variant="soft" className="plm:text-foreground">OP</Badge> : null}
                </div>
                <span className="plm:text-sm plm:text-foreground/80">{player.ping === null ? '—' : `${player.ping} ms`}</span>
                <div className="plm:flex plm:flex-wrap plm:gap-2">
                    {available(player, can).map((action) => (
                        <Button key={action} color="grey" isSecondary size="small" aria-label={ACTIONS[action].button(player.name)} disabled={busy} onClick={() => onAsk(action)}>
                            {action === 'kick' ? 'Kick' : action === 'ban' ? 'Ban' : action === 'op' ? 'Make OP' : 'Remove OP'}
                        </Button>
                    ))}
                </div>
            </div>
            {children}
        </li>
    );
}
