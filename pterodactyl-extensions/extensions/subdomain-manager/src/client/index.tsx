import './styles.css';
import { definePterodactylExtension } from '@pterodactyl/sdk';
import { SubdomainInput } from './SubdomainInput';

export default definePterodactylExtension({
    setup({ forms, screens }) {
        // Draws the label and domain fields of SubdomainFields (src/Fields) on the admin server form.
        forms.extend('admin.server', SubdomainInput);

        // Declared in extension.json (ui.screens): /panel/subdomains.
        screens.register('subdomains', () => import('./screens/Subdomains'));
    },
});
