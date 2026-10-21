import './styles.css';
import { definePterodactylExtension } from '@pterodactyl/sdk';
import PlayerCountWidget from './PlayerCountWidget';
import { RconInput } from './RconInput';

export default definePterodactylExtension({
    setup({ slots, screens, forms }) {
        // Draws the RCON fields of RconFields (src/Fields) on the admin server form. Without this the Panel shows
        // nothing for them, and a server could never be given its RCON host, port and password.
        forms.extend('admin.server', RconInput);

        // "X / Y players online" above the console, for someone with ext.player-manager.read (FR-PM12).
        slots.register('server.console.before', PlayerCountWidget);

        // Declared in extension.json (ui.screens): the Players page, only for someone with ext.player-manager.read.
        screens.register('players', () => import('./PlayerScreen'));
    },
});
