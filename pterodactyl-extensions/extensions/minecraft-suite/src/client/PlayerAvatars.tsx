import { useState } from 'react';
import { crafatarUrl } from './crafatar';

function Avatar({ name, uuid }: { name: string; uuid: string | null }) {
    const [failed, setFailed] = useState(false);
    const url = crafatarUrl('avatar', uuid, 64);

    if (url === null || failed) {
        return (
            <span aria-hidden="true" className="mcs:flex mcs:size-8 mcs:items-center mcs:justify-center mcs:rounded-sm mcs:bg-muted mcs:text-sm mcs:font-medium">
                {(name.charAt(0) || '?').toUpperCase()}
            </span>
        );
    }

    return <img src={url} alt={name} width={32} height={32} loading="lazy" onError={() => setFailed(true)} className="mcs:size-8 mcs:rounded-sm mcs:bg-muted" />;
}

/**
 * A row of player avatars from Crafatar. A valid UUID gets a lazily loaded image; any other UUID, or an image that
 * fails to load, gets the first letter of the name instead (FR-MS11). Given a list of players by whoever mounts it:
 * this extension does not read the player list itself.
 */
export function PlayerAvatars({ players }: { players: { name: string; uuid: string | null }[] }) {
    return (
        <ul className="mcs:flex mcs:flex-wrap mcs:gap-2">
            {players.map((player, index) => (
                <li key={`${player.uuid ?? player.name}-${index}`}>
                    <Avatar name={player.name} uuid={player.uuid} />
                </li>
            ))}
        </ul>
    );
}
