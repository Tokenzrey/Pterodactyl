import type { SdkServer, SlotComponentProps } from '@pterodactyl/sdk';
import { useServerPermission } from '@pterodactyl/sdk';
import { formatTps, LEVEL_TEXT, tpsLevel } from './health';
import { useHealth } from './useHealth';

/** "TPS 19.98 · Healthy" above the console, for someone who may read. It asks for nothing otherwise. */
export default function TpsWidget({ data }: SlotComponentProps<SdkServer>) {
    const canRead = useServerPermission('ext.minecraft-suite.read');
    const health = useHealth(data.attributes.uuid, canRead);

    if (!canRead) {
        return null;
    }
    if (health.isError) {
        return <p className="mcs:text-sm mcs:text-foreground/80">TPS unavailable</p>;
    }
    if (!health.data) {
        return null;
    }

    const tps = health.data.health.tps['1m'];
    const level = tpsLevel(tps);

    return <p className="mcs:text-sm mcs:text-foreground/80">{level === 'unknown' ? 'TPS N/A' : `TPS ${formatTps(tps)} · ${LEVEL_TEXT[level]}`}</p>;
}
