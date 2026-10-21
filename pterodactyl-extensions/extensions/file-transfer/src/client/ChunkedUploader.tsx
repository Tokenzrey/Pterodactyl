import { Button, Dialog, FileInput, Input, Label, ProgressBar } from '@pterodactyl/sdk';
import { useEffect, useId, useRef, useState } from 'react';
import { describeError } from './api';
import type { TransferConfig } from './config';
import { Notice } from './Notice';
import { displayDirectory, formatBytes, isValidFileName, relativeDirectory, suggestFileName } from './paths';
import { MIB, uploadFile, UploadCancelled, type UploadProgress } from './upload';

type Stage = { name: 'choose' } | { name: 'sending'; progress: UploadProgress | null } | { name: 'done'; filename: string } | { name: 'failed'; error: unknown };

/** What "Sending…" says: where the upload is, in words. */
export function progressText(progress: UploadProgress | null): string {
    if (progress === null) {
        return 'Starting…';
    }
    if (progress.phase === 'finishing') {
        return 'Finishing: joining the pieces and handing the file to the server…';
    }

    return `Sent ${formatBytes(progress.sent)} of ${formatBytes(progress.total)} (piece ${progress.chunk} of ${progress.chunks})`;
}

/**
 * Sends one large file to the folder the file manager is showing, in pieces, so a file the browser could not post whole
 * still gets there. Nothing is sent until the person has chosen a file and a valid name, and a cancel stops at once.
 */
export function ChunkedUploader({ serverUuid, directory, config, onClose, onUploaded }: {
    serverUuid: string;
    directory: string;
    config: TransferConfig;
    onClose: () => void;
    /** Called once the file is on the server, so the file list can show it. */
    onUploaded: () => void;
}) {
    const fileId = useId();
    const nameId = useId();
    const nameHelpId = useId();
    const [file, setFile] = useState<File | null>(null);
    const [name, setName] = useState('');
    const [stage, setStage] = useState<Stage>({ name: 'choose' });
    const controller = useRef<AbortController | null>(null);
    const maxBytes = config.maxFileMb * MIB;

    // Closing the dialog, or leaving the page, must not leave an upload running behind it.
    useEffect(() => () => controller.current?.abort(), []);

    const tooLarge = file !== null && file.size > maxBytes;
    const nameOk = isValidFileName(name);
    const canStart = file !== null && !tooLarge && nameOk;

    const choose = (picked: File | null) => {
        setFile(picked);
        setName(picked ? suggestFileName(picked.name) : '');
    };

    const start = async () => {
        if (!file || !canStart) {
            return;
        }

        const abort = new AbortController();
        controller.current = abort;
        setStage({ name: 'sending', progress: null });

        try {
            await uploadFile({
                serverUuid,
                file,
                filename: name,
                directory: relativeDirectory(directory),
                chunkBytes: config.chunkSizeMb * MIB,
                signal: abort.signal,
                onProgress: (progress) => setStage({ name: 'sending', progress }),
            });
            setStage({ name: 'done', filename: name });
            onUploaded();
        } catch (error) {
            // A cancel was asked for: the dialog is already going away, or the person is back at the choice.
            setStage(error instanceof UploadCancelled ? { name: 'choose' } : { name: 'failed', error });
        } finally {
            controller.current = null;
        }
    };

    const cancel = () => controller.current?.abort();
    const sending = stage.name === 'sending';
    const close = () => {
        cancel();
        onClose();
    };

    return (
        <Dialog open onClose={close} title="Upload a large file" description={`The file is sent in pieces to ${displayDirectory(directory)} on this server.`} preventExternalClose={sending}>
            {stage.name === 'choose' || stage.name === 'failed' ? (
                <form
                    className="ftr:flex ftr:flex-col ftr:gap-4"
                    onSubmit={(event) => {
                        event.preventDefault();
                        void start();
                    }}
                >
                    {stage.name === 'failed' ? (
                        <Notice tone="danger" title={describeError(stage.error).title}>
                            {describeError(stage.error).body}
                        </Notice>
                    ) : null}

                    <div>
                        <Label htmlFor={fileId}>File</Label>
                        <FileInput id={fileId} onChange={(event) => choose(event.target.files?.[0] ?? null)} aria-describedby={tooLarge ? `${fileId}-error` : undefined} aria-invalid={tooLarge || undefined} />
                        {tooLarge ? (
                            <p id={`${fileId}-error`} role="alert" className="ftr:mt-1 ftr:text-sm ftr:text-destructive">
                                This file is {formatBytes(file.size)}. The limit is {formatBytes(maxBytes)}.
                            </p>
                        ) : (
                            <p className="ftr:mt-1 ftr:text-sm ftr:text-foreground/80">Up to {formatBytes(maxBytes)}.</p>
                        )}
                    </div>

                    <div>
                        <Label htmlFor={nameId}>Save as</Label>
                        <Input id={nameId} value={name} onChange={(event) => setName(event.target.value)} maxLength={255} autoComplete="off" spellCheck={false} aria-invalid={name !== '' && !nameOk ? true : undefined} aria-describedby={nameHelpId} />
                        <p id={nameHelpId} className={`ftr:mt-1 ftr:text-sm ${name !== '' && !nameOk ? 'ftr:text-destructive' : 'ftr:text-foreground/80'}`}>
                            Letters, digits, dots, hyphens and underscores only. An existing file with this name is replaced.
                        </p>
                    </div>

                    <Dialog.Footer>
                        <Button type="button" color="grey" isSecondary onClick={close}>
                            Close
                        </Button>
                        <Button type="submit" disabled={!canStart}>
                            {stage.name === 'failed' ? 'Try again' : 'Upload'}
                        </Button>
                    </Dialog.Footer>
                </form>
            ) : null}

            {stage.name === 'sending' ? (
                <div className="ftr:flex ftr:flex-col ftr:gap-4">
                    <ProgressBar value={stage.progress === null || stage.progress.phase === 'finishing' ? null : Math.floor((stage.progress.sent / Math.max(1, stage.progress.total)) * 100)} label={`Uploading ${name}`} />
                    <p role="status" aria-live="polite" className="ftr:text-sm">
                        {progressText(stage.progress)}
                    </p>
                    <p className="ftr:text-sm ftr:text-foreground/80">Keep this page open until it finishes.</p>
                    <Dialog.Footer>
                        <Button type="button" color="grey" isSecondary onClick={cancel}>
                            Cancel upload
                        </Button>
                    </Dialog.Footer>
                </div>
            ) : null}

            {stage.name === 'done' ? (
                <div className="ftr:flex ftr:flex-col ftr:gap-4">
                    <Notice tone="success" title={`${stage.filename} is on the server`}>
                        It is in {displayDirectory(directory)}.
                    </Notice>
                    <Dialog.Footer>
                        <Button type="button" onClick={onClose}>
                            Done
                        </Button>
                    </Dialog.Footer>
                </div>
            ) : null}
        </Dialog>
    );
}
