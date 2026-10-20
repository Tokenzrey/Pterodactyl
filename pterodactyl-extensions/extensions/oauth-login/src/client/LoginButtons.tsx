import { LinkButton } from '@pterodactyl/sdk';
import { useEffect, useState, type MouseEvent } from 'react';
import type { OauthConfig, ProviderId } from './config';
import { ProviderIcon } from './icons';
import { PROVIDER_LABELS, redirectPath } from './messages';
import { readLastProvider, rememberProvider } from './storage';

/**
 * "or continue with": one button per enabled provider under the password form. The provider this browser used
 * last comes first. After a click the page is on its way to the provider, so every button shows it and ignores
 * further clicks. Renders nothing when no provider is enabled.
 */
export function LoginButtons({ providers }: OauthConfig) {
    const [pending, setPending] = useState<ProviderId | null>(null);
    const [last] = useState(() => readLastProvider(providers));

    // Coming back with the browser's Back button restores this page from memory, mid-click.
    useEffect(() => {
        const reset = () => setPending(null);
        window.addEventListener('pageshow', reset);

        return () => window.removeEventListener('pageshow', reset);
    }, []);

    if (providers.length === 0) {
        return null;
    }

    const ordered = last ? [last, ...providers.filter((id) => id !== last)] : providers;
    const onClick = (id: ProviderId) => (event: MouseEvent) => {
        if (pending !== null) {
            event.preventDefault();

            return;
        }
        rememberProvider(id);
        setPending(id);
    };

    return (
        <section aria-labelledby="olg-heading" className="olg:mt-6">
            <div className="olg:flex olg:items-center olg:gap-3">
                <span aria-hidden="true" className="olg:h-px olg:flex-1 olg:bg-border" />
                <h2 id="olg-heading" className="olg:text-xs olg:font-medium olg:text-foreground/80">
                    or continue with
                </h2>
                <span aria-hidden="true" className="olg:h-px olg:flex-1 olg:bg-border" />
            </div>

            <ul className="olg:mt-4 olg:flex olg:flex-col olg:gap-2" aria-busy={pending !== null}>
                {ordered.map((id) => (
                    <li key={id}>
                        <LinkButton
                            href={redirectPath(id)}
                            color="grey"
                            isSecondary
                            size="large"
                            onClick={onClick(id)}
                            aria-disabled={pending !== null && pending !== id}
                            className="olg:flex olg:w-full olg:items-center olg:justify-center olg:gap-3"
                        >
                            <ProviderIcon id={id} />
                            <span>{pending === id ? `Opening ${PROVIDER_LABELS[id]}…` : `Continue with ${PROVIDER_LABELS[id]}`}</span>
                            {id === last && pending !== id ? (
                                <span className="olg:rounded olg:bg-muted olg:px-1.5 olg:py-0.5 olg:text-[10px] olg:font-medium olg:text-foreground/80">Last used</span>
                            ) : null}
                        </LinkButton>
                    </li>
                ))}
            </ul>
        </section>
    );
}
