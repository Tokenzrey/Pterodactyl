import './styles.css';
import { definePterodactylExtension } from '@pterodactyl/sdk';
import { SubdomainInput } from './SubdomainInput';
import AddressWidget from './AddressWidget';
import DashboardAddress from './DashboardAddress';

export default definePterodactylExtension({
    setup({ forms, screens, slots }) {
        // Draws the label and domain fields of SubdomainFields (src/Fields) on the admin server form.
        forms.extend('admin.server', SubdomainInput);

        // "Players join with ..." above the server console, for whoever may open the server (the owner's address API).
        slots.register('server.console.before', AddressWidget);

        // The same address under each server's name on the owner's dashboard.
        slots.register('dashboard.serverRow.name.after', DashboardAddress);

        // Declared in extension.json (ui.screens): /panel/subdomains.
        screens.register('subdomains', () => import('./screens/Subdomains'));
    },
});
