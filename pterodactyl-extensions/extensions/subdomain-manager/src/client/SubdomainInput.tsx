import { Badge, Button, CopyOnClick, Input, Label, Select, type FormExtensionProps } from '@pterodactyl/sdk';
import { useQuery } from '@tanstack/react-query';
import { Check, CircleAlert, Copy, LoaderCircle, Trash2 } from 'lucide-react';
import { useEffect } from 'react';
import { fetchConfig } from './api';
import { Notice } from './Notice';
import { errorAdvice, fqdn, isStatus, labelProblem, REASON_TEXT, STATUS_META } from './labels';
import { useAvailability } from './useAvailability';

/** What the backend's SubdomainFields returns and accepts; `label` and `domain` are edited, the rest is read only. */
export type SubdomainValues = {
    label: string;
    domain: string;
    status: string | null;
    fqdn: string | null;
    error: string | null;
};

/**
 * The "subdomain" block of the admin server form (create and edit). It builds one address from two inputs, shows
 * the address as players will type it, checks it is free while the administrator types, and, for a saved
 * subdomain, says where it stands and what to do about a problem.
 */
export function SubdomainInput({ resource, values, field }: FormExtensionProps<SubdomainValues, 'admin.server'>) {
    const config = useQuery({ queryKey: ['subdomain-manager', 'config'], queryFn: fetchConfig, staleTime: 60_000, retry: 1, retryDelay: 300 });
    const label = field('label');
    const domain = field('domain');
    const labelValue = label.value ?? '';
    const domainValue = domain.value ?? '';
    const domains = config.data?.domains ?? [];
    const serverId = resource?.attributes.id;
    const hasAddress = labelValue !== '' && domainValue !== '';

    // A label without a domain can never be saved: start from the first configured domain.
    useEffect(() => {
        if (labelValue !== '' && domainValue === '' && domains.length > 0) {
            domain.setValue(domains[0]);
        }
        // `domain.setValue` is a new function on every render, so it is left out of the dependencies on purpose.
    }, [labelValue, domainValue, domains.join('|')]);

    const local = config.data ? labelProblem(labelValue, config.data.reserved_labels) : null;
    const availability = useAvailability(domainValue, labelValue, serverId, Boolean(config.data) && hasAddress && local === null);

    const savedAddress = values.fqdn;
    const removing = labelValue === '' && Boolean(savedAddress);
    const status = isStatus(values.status) ? STATUS_META[values.status] : null;
    const advice = errorAdvice(values.error ?? null);
    const address = hasAddress ? fqdn(labelValue, domainValue) : null;

    return (
        <section aria-labelledby="sdm-heading" className="sdm:mt-6 sdm:flex sdm:flex-col sdm:gap-4">
            <div>
                <h3 id="sdm-heading" className="sdm:text-base sdm:font-semibold">
                    Subdomain
                </h3>
                <p className="sdm:text-sm sdm:text-foreground/80">A name players can type instead of an IP address. Leave the label empty if the server has none.</p>
            </div>

            {config.isError ? (
                <Notice tone="danger" title="The subdomain settings could not be loaded">
                    Reload the page to try again.
                </Notice>
            ) : null}
            {config.data && domains.length === 0 ? (
                <Notice tone="warning" title="No domain is configured yet">
                    Add one in Admin → Extensions → Subdomain Manager before giving a server a name.
                </Notice>
            ) : null}

            <div className="sdm:grid sdm:gap-3 sdm:sm:grid-cols-2">
                <div>
                    <Label htmlFor={label.id}>Label</Label>
                    <Input
                        id={label.id}
                        name={label.name}
                        value={labelValue}
                        onChange={(event) => label.setValue(event.target.value.toLowerCase())}
                        disabled={domains.length === 0}
                        maxLength={63}
                        autoComplete="off"
                        spellCheck={false}
                        placeholder="kampung"
                        aria-invalid={Boolean(label.error) || local !== null}
                        aria-describedby="sdm-address sdm-check"
                        $hasError={Boolean(label.error) || local !== null}
                    />
                </div>
                <div>
                    <Label htmlFor={domain.id}>Domain</Label>
                    <Select
                        id={domain.id}
                        value={domainValue}
                        onChange={(value) => domain.setValue(String(value))}
                        options={domains.map((name) => ({ value: name, label: name }))}
                        placeholder="Choose a domain"
                        disabled={domains.length === 0}
                        hasError={Boolean(domain.error)}
                        aria-invalid={Boolean(domain.error)}
                        aria-describedby="sdm-address"
                    />
                </div>
            </div>

            <div id="sdm-address" aria-live="polite" className="sdm:rounded-md sdm:border sdm:border-border sdm:bg-muted sdm:p-3">
                {address ? (
                    <>
                        <p className="sdm:text-xs sdm:text-foreground/80">Players join with</p>
                        <div className="sdm:mt-1 sdm:flex sdm:items-center sdm:gap-2">
                            <code className="sdm:min-w-0 sdm:flex-1 sdm:break-all sdm:font-mono sdm:text-sm sdm:font-semibold">{address}</code>
                            <CopyOnClick text={address}>
                                <button type="button" aria-label="Copy address" className="sdm:rounded sdm:p-1.5 sdm:text-foreground/80 sdm:hover:text-foreground">
                                    <Copy aria-hidden="true" className="sdm:size-4" />
                                </button>
                            </CopyOnClick>
                        </div>
                        <p className="sdm:mt-1 sdm:text-xs sdm:text-foreground/80">
                            {config.data?.srv_enabled === false ? 'The server port must be added after the name.' : 'No port needed: an SRV record points the name at the right port.'}
                        </p>
                    </>
                ) : removing ? (
                    <p className="sdm:text-sm">
                        Saving with an empty label removes <code className="sdm:font-mono">{savedAddress}</code> from Cloudflare.
                    </p>
                ) : (
                    <p className="sdm:text-sm sdm:text-foreground/80">Type a label to see the address players will use.</p>
                )}
            </div>

            <p id="sdm-check" role="status" aria-live="polite" className="sdm:flex sdm:min-h-5 sdm:items-center sdm:gap-1.5 sdm:text-sm">
                {local ? <CircleAlert aria-hidden="true" className="sdm:size-4 sdm:shrink-0 sdm:text-destructive" /> : null}
                {availability.kind === 'checking' ? <LoaderCircle aria-hidden="true" className="sdm:size-4 sdm:shrink-0 sdm:motion-safe:animate-spin" /> : null}
                {availability.kind === 'failed' ? <CircleAlert aria-hidden="true" className="sdm:size-4 sdm:shrink-0 sdm:text-warning" /> : null}
                {availability.kind === 'done' && availability.answer.available ? <Check aria-hidden="true" className="sdm:size-4 sdm:shrink-0 sdm:text-success" /> : null}
                {availability.kind === 'done' && !availability.answer.available ? <CircleAlert aria-hidden="true" className="sdm:size-4 sdm:shrink-0 sdm:text-destructive" /> : null}
                <span>
                    {local ? REASON_TEXT[local] : null}
                    {availability.kind === 'checking' ? 'Checking…' : null}
                    {availability.kind === 'failed' ? 'Availability could not be checked.' : null}
                    {availability.kind === 'done' && availability.answer.available
                        ? availability.answer.checked_cloudflare
                            ? 'Available.'
                            : 'Available (not checked at Cloudflare right now).'
                        : null}
                    {availability.kind === 'done' && !availability.answer.available && availability.answer.reason ? REASON_TEXT[availability.answer.reason] : null}
                </span>
            </p>

            {label.error ? (
                <Notice tone="danger" title="The label was not saved">
                    {label.error}
                </Notice>
            ) : null}
            {domain.error ? (
                <Notice tone="danger" title="The domain was not saved">
                    {domain.error}
                </Notice>
            ) : null}

            {status ? (
                <div className="sdm:rounded-md sdm:border sdm:border-border sdm:p-3">
                    <div className="sdm:flex sdm:items-center sdm:gap-2">
                        <span className="sdm:text-sm sdm:font-medium">Status</span>
                        <Badge tone={status.tone} variant="soft" className={status.tone === 'neutral' || status.tone === 'warning' ? 'sdm:text-foreground' : undefined}>
                            {status.text}
                        </Badge>
                    </div>
                    <p className="sdm:mt-1 sdm:text-sm sdm:text-foreground/80">{status.help}</p>
                    {values.error ? (
                        <p className="sdm:mt-2 sdm:text-sm">
                            <span className="sdm:font-medium">Last error:</span> {values.error}
                            {advice ? <span className="sdm:block sdm:text-foreground/80">{advice}</span> : null}
                        </p>
                    ) : null}
                </div>
            ) : null}

            {labelValue !== '' && savedAddress ? (
                <div>
                    <Button color="grey" isSecondary size="small" type="button" onClick={() => label.setValue('')}>
                        <Trash2 aria-hidden="true" className="sdm:mr-1.5 sdm:size-4" />
                        Clear label
                    </Button>
                </div>
            ) : null}
        </section>
    );
}
