import { CopyOnClick, type SdkServer, type SlotComponentProps } from '@pterodactyl/sdk';
import { useQuery } from '@tanstack/react-query';
import { Copy } from 'lucide-react';
import { fetchServerAddress, serverAddressKey } from './api';

/**
 * The address players type, above the server console, for whoever may open the server. It shows the name only: no
 * token, no zone, and nothing about the administrator's settings beyond what players need to know.
 */
export default function AddressWidget({ data }: SlotComponentProps<SdkServer>) {
    const uuid = data.attributes.uuid;
    const address = useQuery({ queryKey: serverAddressKey(uuid), queryFn: () => fetchServerAddress(uuid), staleTime: 30_000, retry: 1, retryDelay: 300 });

    if (address.isError) {
        return <p className="sdm:text-sm sdm:text-foreground/80">Address unavailable</p>;
    }
    if (!address.data) {
        return null;
    }

    const { address: name, needs_port: needsPort, routing } = address.data;
    if (name === null) {
        return <p className="sdm:text-sm sdm:text-foreground/80">No address yet. An administrator sets one for this server.</p>;
    }

    return (
        <div className="sdm:flex sdm:flex-col sdm:gap-1">
            <div className="sdm:flex sdm:items-center sdm:gap-2">
                <span className="sdm:text-sm sdm:text-foreground/80">Players join with</span>
                <code className="sdm:font-mono sdm:text-sm sdm:font-semibold sdm:break-all">{name}</code>
                <CopyOnClick text={name}>
                    <button type="button" aria-label="Copy address" className="sdm:rounded sdm:p-1.5 sdm:text-foreground/80 sdm:hover:text-foreground">
                        <Copy aria-hidden="true" className="sdm:size-4" />
                    </button>
                </CopyOnClick>
            </div>
            {needsPort ? <p className="sdm:text-xs sdm:text-foreground/80">Add the server port after the name.</p> : null}
            {routing ? (
                <p className="sdm:text-xs sdm:text-foreground/80">{routing.state === 'ready' ? 'Routed to this server.' : `Not routed: ${routing.reason ?? 'unknown reason'}.`}</p>
            ) : null}
        </div>
    );
}
