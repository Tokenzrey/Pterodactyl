import './styles.css';
import { definePterodactylExtension } from '@pterodactyl/sdk';
import { RconInput } from './RconInput';
import TpsWidget from './TpsWidget';

export default definePterodactylExtension({
    setup({ slots, screens, forms }) {
        // Draws the RCON fields of RconFields (src/Fields) on the admin server form. Without this the Panel shows
        // nothing for them, and a server could never be given its RCON host, port and password.
        forms.extend('admin.server', RconInput);

        // "TPS 19.98 · Healthy" above the console, for someone with ext.minecraft-suite.read (FR-MS8).
        slots.register('server.console.before', TpsWidget);

        // Declared in extension.json (ui.screens): the Health page, only for someone with ext.minecraft-suite.read.
        screens.register('health', () => import('./HealthScreen'));
    },
});
