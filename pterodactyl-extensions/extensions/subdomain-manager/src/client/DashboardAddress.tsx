import type { SdkServer, SlotComponentProps } from '@pterodactyl/sdk';
import { useQuery } from '@tanstack/react-query';
import { fetchServerAddress, serverAddressKey } from './api';

/**
 * The address under a server's name on the owner's dashboard. Nothing is shown when there is no address, so a list of
 * servers without subdomains stays as it was.
 */
export default function DashboardAddress({ data }: SlotComponentProps<SdkServer>) {
    const uuid = data.attributes.uuid;
    const address = useQuery({ queryKey: serverAddressKey(uuid), queryFn: () => fetchServerAddress(uuid), staleTime: 30_000, retry: 1, retryDelay: 300 });

    if (!address.data?.address) {
        return null;
    }

    return (
        <span className="sdm:block sdm:font-mono sdm:text-xs sdm:text-foreground/80">
            {address.data.address}
            {address.data.routing?.state === 'invalid' ? ' · not routed' : null}
        </span>
    );
}
