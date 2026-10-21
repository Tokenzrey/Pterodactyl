import type { SdkServer, SlotComponentProps } from '@pterodactyl/sdk';
import { useServerPermission } from '@pterodactyl/sdk';
import { countText, usePlayers } from './usePlayers';

/** "3 / 20 players online" above the console, for someone who may read the list. It asks for nothing otherwise. */
export default function PlayerCountWidget({ data }: SlotComponentProps<SdkServer>) {
    const canRead = useServerPermission('ext.player-manager.read');
    const players = usePlayers(data.attributes.uuid, canRead);

    if (!canRead) {
        return null;
    }
    if (players.isError) {
        return <p className="plm:text-sm plm:text-foreground/80">Player count unavailable</p>;
    }
    if (!players.data) {
        return null;
    }

    return <p className="plm:text-sm plm:text-foreground/80">{countText(players.data.list.online_count, players.data.list.max_count)}</p>;
}
