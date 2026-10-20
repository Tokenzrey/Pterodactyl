import './styles.css';
import { defineConfiguredExtension } from '@pterodactyl/sdk';
import { parseConfig } from './config';
import { ErrorBanner } from './ErrorBanner';
import { LoginButtons } from './LoginButtons';

export default defineConfiguredExtension(parseConfig, {
    setup({ config, slots, screens }) {
        slots.register('auth.login.form.after', () => <LoginButtons providers={config.providers} />);
        slots.register('auth.login.before', ErrorBanner);

        // Declared in extension.json (ui.screens): /account/connected-accounts.
        screens.register('accounts', () => import('./screens/ConnectedAccounts'));
    },
});
