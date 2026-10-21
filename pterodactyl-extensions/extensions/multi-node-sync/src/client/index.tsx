import './styles.css';
import { definePterodactylExtension } from '@pterodactyl/sdk';

export default definePterodactylExtension({
    setup({ screens }) {
        screens.register('migrations', () => import('./MigrationScreen'));
        screens.register('s3-transfer', () => import('./S3TransferScreen'));
    },
});
