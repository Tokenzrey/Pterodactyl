import { Badge, Card, ServerContentBlock, Spinner, useCurrentServerRequired } from '@pterodactyl/sdk';
import { describeError, type Health } from './api';
import { formatMspt, formatTps, formatUptime, LEVEL_TEXT, LEVEL_TONE, tpsLevel } from './health';
import { Notice } from './Notice';
import { useHealth } from './useHealth';

const TPS_ROWS = [
    ['1m', 'TPS, last minute'],
    ['5m', 'TPS, last 5 minutes'],
    ['15m', 'TPS, last 15 minutes'],
] as const;

function Row({ label, children }: { label: string; children: React.ReactNode }) {
    return (
        <div className="mcs:flex mcs:items-center mcs:justify-between mcs:gap-4 mcs:py-2.5 mcs:first:pt-0 mcs:last:pb-0">
            <dt className="mcs:text-sm mcs:text-foreground/80">{label}</dt>
            <dd className="mcs:flex mcs:items-center mcs:gap-2 mcs:font-medium">{children}</dd>
        </div>
    );
}

function Readings({ health }: { health: Health }) {
    return (
        <Card title="Server performance">
            <dl className="mcs:divide-y mcs:divide-border">
                {TPS_ROWS.map(([key, label]) => {
                    const level = tpsLevel(health.tps[key]);

                    return (
                        <Row key={key} label={label}>
                            <span>{formatTps(health.tps[key])}</span>
                            {level === 'unknown' ? null : (
                                <Badge tone={LEVEL_TONE[level]} variant="soft" className={level === 'warn' ? 'mcs:text-foreground' : undefined}>
                                    {LEVEL_TEXT[level]}
                                </Badge>
                            )}
                        </Row>
                    );
                })}
                <Row label="MSPT (time per tick)">
                    <span>{formatMspt(health.mspt)}</span>
                </Row>
                <Row label="Uptime">
                    <span>{formatUptime(health.uptime_seconds)}</span>
                </Row>
                <Row label="Version">
                    <span>{health.version ?? 'N/A'}</span>
                </Row>
            </dl>
        </Card>
    );
}

/** The current server's TPS, MSPT and uptime, refreshed on the interval its settings give. */
export default function HealthScreen() {
    const health = useHealth(useCurrentServerRequired().attributes.uuid);
    const noReading = health.data !== undefined && Object.values(health.data.health.tps).every((value) => value === null);

    return (
        <ServerContentBlock title="Health">
            {health.isPending ? (
                <div role="status" className="mcs:flex mcs:items-center mcs:gap-3 mcs:text-sm mcs:text-foreground/80">
                    <Spinner size="small" />
                    Loading health…
                </div>
            ) : null}

            {health.isError ? (
                <Notice tone="danger" title={describeError(health.error).title}>
                    {describeError(health.error).body} This page keeps trying on its own.
                </Notice>
            ) : null}

            {noReading ? (
                <div className="mcs:mb-4">
                    <Notice tone="info" title="No TPS reading">
                        The server may be off, or it has no TPS command. An administrator can check the TPS command in this server&rsquo;s settings.
                    </Notice>
                </div>
            ) : null}

            {health.data ? <Readings health={health.data.health} /> : null}
        </ServerContentBlock>
    );
}
