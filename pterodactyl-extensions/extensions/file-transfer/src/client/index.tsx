import './styles.css';
import { defineConfiguredExtension } from '@pterodactyl/sdk';
import { parseConfig } from './config';
import { FileTransferToolbar } from './FileTransferToolbar';

export default defineConfiguredExtension(parseConfig, {
    setup({ config, slots }) {
        // Two buttons in the file manager's toolbar. The piece size and the largest file come from the public settings.
        slots.register('server.files.toolbar', (props) => <FileTransferToolbar {...props} config={config} />);
    },
});
