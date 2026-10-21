import { Button, useServerPermission, type FileManagerSlotData, type SlotComponentProps } from '@pterodactyl/sdk';
import { Link2, Upload } from 'lucide-react';
import { useState } from 'react';
import { ChunkedUploader } from './ChunkedUploader';
import type { TransferConfig } from './config';
import { RemoteFetchDialog } from './RemoteFetchDialog';

/**
 * Two buttons beside the file manager's own: one for a file too large to send in one go, one for a file that lives at an
 * address. Each shows only for someone who may use it (file.create; ext.file-transfer.remote-fetch, FR-FT14), and the backend asks again.
 */
export function FileTransferToolbar({ data, config }: SlotComponentProps<FileManagerSlotData> & { config: TransferConfig }) {
    const canUpload = useServerPermission('file.create');
    const canFetch = useServerPermission('ext.file-transfer.remote-fetch');
    const [dialog, setDialog] = useState<'upload' | 'fetch' | null>(null);

    if (!canUpload && !canFetch) {
        return null;
    }

    const close = () => setDialog(null);

    return (
        <>
            {canUpload ? (
                <Button type="button" color="grey" isSecondary size="small" onClick={() => setDialog('upload')}>
                    <Upload aria-hidden="true" focusable="false" className="ftr:mr-2 ftr:size-4" />
                    Upload large file
                </Button>
            ) : null}
            {canFetch ? (
                <Button type="button" color="grey" isSecondary size="small" onClick={() => setDialog('fetch')}>
                    <Link2 aria-hidden="true" focusable="false" className="ftr:mr-2 ftr:size-4" />
                    Fetch from address
                </Button>
            ) : null}

            {dialog === 'upload' ? <ChunkedUploader serverUuid={data.server.attributes.uuid} directory={data.directory} config={config} onClose={close} onUploaded={() => void data.refresh()} /> : null}
            {dialog === 'fetch' ? <RemoteFetchDialog serverUuid={data.server.attributes.uuid} directory={data.directory} onClose={close} onFetched={() => void data.refresh()} /> : null}
        </>
    );
}
