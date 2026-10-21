import { Button, Dialog, Input, Label } from '@pterodactyl/sdk';
import { useMutation } from '@tanstack/react-query';
import { useId, useRef, useState } from 'react';
import { describeError, folderError, installModpack, type ModpackFile, type ModpackResult } from './api';
import { Notice } from './Notice';

/**
 * Asks before a pack goes onto the server: which pack, into which folder, and what that does to files already there.
 * It sends the ids and the folder, nothing else; the Panel looks the file up itself.
 */
export function InstallDialog({ serverUuid, result, file, onClose, onStarted }: {
    serverUuid: string;
    result: ModpackResult;
    file: ModpackFile;
    onClose: () => void;
    onStarted: (jobId: string) => void;
}) {
    const folderId = useId();
    const helpId = useId();
    const [folder, setFolder] = useState('');
    const problem = folderError(folder);
    // isPending reaches the screen a moment after mutate(); a second press in that moment must not start a second install.
    const sending = useRef(false);

    const install = useMutation({
        mutationFn: () => installModpack(serverUuid, { source: result.source, project_id: result.project_id, file_id: file.file_id, ...(folder === '' ? {} : { target_directory: folder }) }),
        onSuccess: (jobId) => onStarted(jobId),
        onSettled: () => {
            sending.current = false;
        },
    });

    return (
        <Dialog open onClose={onClose} preventExternalClose={install.isPending} title={`Install ${result.name}?`} description={`The server pack ${file.name} is downloaded by the Panel and unpacked on this server.`}>
            <form
                className="mki:flex mki:flex-col mki:gap-4"
                onSubmit={(event) => {
                    event.preventDefault();
                    if (problem === null && !sending.current) {
                        sending.current = true;
                        install.mutate();
                    }
                }}
            >
                {install.isError ? (
                    <Notice tone="danger" title={describeError(install.error).title}>
                        {describeError(install.error).body}
                    </Notice>
                ) : null}

                <div>
                    <Label htmlFor={folderId}>Install into folder (optional)</Label>
                    <Input id={folderId} value={folder} onChange={(event) => setFolder(event.target.value)} maxLength={255} autoComplete="off" spellCheck={false} placeholder="Leave empty for the main folder" aria-invalid={problem !== null ? true : undefined} aria-describedby={helpId} />
                    <p id={helpId} className={`mki:mt-1 mki:text-sm ${problem !== null ? 'mki:text-destructive' : 'mki:text-foreground/80'}`}>
                        {problem ?? 'Files in the pack replace files with the same name. Launch scripts such as start.sh are removed afterwards.'}
                    </p>
                </div>

                <Dialog.Footer>
                    <Button type="button" color="grey" isSecondary onClick={onClose} disabled={install.isPending}>
                        Cancel
                    </Button>
                    <Button type="submit" disabled={problem !== null} isLoading={install.isPending}>
                        {install.isError ? 'Try again' : 'Install'}
                    </Button>
                </Dialog.Footer>
            </form>
        </Dialog>
    );
}
