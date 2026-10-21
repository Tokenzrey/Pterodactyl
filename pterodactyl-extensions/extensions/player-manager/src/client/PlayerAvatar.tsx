import { useState } from 'react';
import { crafatarUrl } from './crafatar';

/** A Crafatar avatar for a valid UUID, lazily loaded. A letter takes its place with no UUID, or when the image fails. */
export function PlayerAvatar({ name, uuid }: { name: string; uuid: string | null }) {
    const [failed, setFailed] = useState(false);
    const url = crafatarUrl('avatar', uuid, 64);

    if (url === null || failed) {
        return (
            <span aria-hidden="true" className="plm:flex plm:size-8 plm:shrink-0 plm:items-center plm:justify-center plm:rounded-sm plm:bg-muted plm:text-sm plm:font-medium">
                {(name.charAt(0) || '?').toUpperCase()}
            </span>
        );
    }

    return <img src={url} alt={name} width={32} height={32} loading="lazy" onError={() => setFailed(true)} className="plm:size-8 plm:shrink-0 plm:rounded-sm plm:bg-muted" />;
}
