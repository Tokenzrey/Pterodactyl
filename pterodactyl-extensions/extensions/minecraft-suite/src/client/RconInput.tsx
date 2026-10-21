import { Input, Label, type FormExtensionProps } from '@pterodactyl/sdk';
import type { ReactNode } from 'react';

/** What the backend sends in place of a stored password. Sent back unchanged, it means "keep the one that is saved". */
export const MASK = '********';

/** What RconFields (src/Fields) returns and accepts for a server. */
export type RconValues = {
    rcon_host: string;
    rcon_port: number | null;
    rcon_password: string;
    tps_command: string;
    poll_interval: number | null;
    cache_seconds: number | null;
};

function Row({ id, label, help, error, children }: { id: string; label: string; help?: ReactNode; error?: string; children: ReactNode }) {
    return (
        <div>
            <Label htmlFor={id}>{label}</Label>
            {children}
            {help ? (
                <p id={`${id}-help`} className="mcs:mt-1 mcs:text-xs mcs:text-foreground/80">
                    {help}
                </p>
            ) : null}
            {error ? (
                <p role="alert" className="mcs:mt-1 mcs:text-sm mcs:text-destructive">
                    {error}
                </p>
            ) : null}
        </div>
    );
}

const toNumber = (text: string): number | null => (text.trim() === '' ? null : Number(text));

/**
 * The RCON fields on the admin server form: where the Panel reaches this server's console, and how the Players
 * page behaves. Only root administrators see it. The password is never shown: a mask means one is saved, and
 * leaving the field as it is keeps it.
 */
export function RconInput({ field }: FormExtensionProps<RconValues, 'admin.server'>) {
    const host = field('rcon_host');
    const port = field('rcon_port');
    const password = field('rcon_password');
    const command = field('tps_command');
    const poll = field('poll_interval');
    const cache = field('cache_seconds');
    const saved = password.value === MASK;

    return (
        <section aria-labelledby="mcs-rcon-heading" className="mcs:mt-6 mcs:flex mcs:flex-col mcs:gap-4">
            <div>
                <h3 id="mcs-rcon-heading" className="mcs:text-base mcs:font-semibold">
                    Minecraft Suite: RCON
                </h3>
                <p className="mcs:text-sm mcs:text-foreground/80">How the Panel reaches this server&rsquo;s console to read its TPS and uptime. Leave the host empty to switch it off for this server.</p>
            </div>

            <div className="mcs:grid mcs:gap-3 mcs:sm:grid-cols-2">
                <Row id={host.id} label="RCON host" error={host.error} help="An address or host name the Panel can reach. 127.0.0.1 when the Panel and the server run on one machine.">
                    <Input
                        id={host.id}
                        name={host.name}
                        value={host.value ?? ''}
                        onChange={(event) => host.setValue(event.target.value.trim())}
                        maxLength={253}
                        autoComplete="off"
                        spellCheck={false}
                        aria-invalid={Boolean(host.error)}
                        aria-describedby={`${host.id}-help`}
                        $hasError={Boolean(host.error)}
                    />
                </Row>
                <Row id={port.id} label="RCON port" error={port.error} help="The rcon.port value in server.properties. Not the game port.">
                    <Input
                        id={port.id}
                        name={port.name}
                        type="number"
                        min={1}
                        max={65535}
                        value={port.value ?? ''}
                        onChange={(event) => port.setValue(toNumber(event.target.value))}
                        aria-invalid={Boolean(port.error)}
                        aria-describedby={`${port.id}-help`}
                        $hasError={Boolean(port.error)}
                    />
                </Row>
            </div>

            <Row
                id={password.id}
                label="RCON password"
                error={password.error}
                help={saved ? 'A password is saved. Leave this as it is to keep it, or type a new one.' : 'No password is saved yet. It is the rcon.password value in server.properties, and it is stored encrypted.'}
            >
                <Input
                    id={password.id}
                    name={password.name}
                    type="password"
                    value={password.value ?? ''}
                    onChange={(event) => password.setValue(event.target.value)}
                    maxLength={256}
                    autoComplete="new-password"
                    spellCheck={false}
                    aria-invalid={Boolean(password.error)}
                    aria-describedby={`${password.id}-help`}
                    $hasError={Boolean(password.error)}
                />
            </Row>

            <Row id={command.id} label="TPS command" error={command.error} help='"spark tps" when the spark plugin is installed, "tps" on Paper or Purpur. A server with neither shows N/A.'>
                <Input
                    id={command.id}
                    name={command.name}
                    value={command.value ?? ''}
                    onChange={(event) => command.setValue(event.target.value)}
                    maxLength={100}
                    autoComplete="off"
                    spellCheck={false}
                    aria-invalid={Boolean(command.error)}
                    aria-describedby={`${command.id}-help`}
                    $hasError={Boolean(command.error)}
                />
            </Row>

            <div className="mcs:grid mcs:gap-3 mcs:sm:grid-cols-2">
                <Row id={poll.id} label="Refresh every (ms)" error={poll.error} help="How often the health page updates while it is open. 5000 to 60000.">
                    <Input
                        id={poll.id}
                        name={poll.name}
                        type="number"
                        min={5000}
                        max={60000}
                        value={poll.value ?? ''}
                        onChange={(event) => poll.setValue(toNumber(event.target.value))}
                        aria-invalid={Boolean(poll.error)}
                        aria-describedby={`${poll.id}-help`}
                        $hasError={Boolean(poll.error)}
                    />
                </Row>
                <Row id={cache.id} label="Cache answers for (seconds)" error={cache.error} help="Several viewers share one RCON call inside this window. 0 turns the cache off.">
                    <Input
                        id={cache.id}
                        name={cache.name}
                        type="number"
                        min={0}
                        max={30}
                        value={cache.value ?? ''}
                        onChange={(event) => cache.setValue(toNumber(event.target.value))}
                        aria-invalid={Boolean(cache.error)}
                        aria-describedby={`${cache.id}-help`}
                        $hasError={Boolean(cache.error)}
                    />
                </Row>
            </div>
        </section>
    );
}
