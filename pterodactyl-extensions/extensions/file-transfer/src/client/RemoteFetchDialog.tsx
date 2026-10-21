import { Button, Dialog, Input, Label, ProgressBar, useExtensionJobProgress } from '@pterodactyl/sdk';
import { useEffect, useId, useRef, useState } from 'react';
import { describeError, describeFailure, remoteFetch } from './api';
import { Notice } from './Notice';
import { displayDirectory, isFetchableUrl, isValidFileName, relativeDirectory } from './paths';

/** The Panel hands the file to the server from 80 percent on; before that it is still downloading. */
export function stepText(percent: number): string {
    return percent >= 80 ? 'Handing the file to the server…' : 'Downloading from the address…';
}

/**
 * Has the Panel download a file from an address and put it in the folder the file manager is showing. The download runs
 * on the Panel, so the person may close the dialog; it stays here to show how far it is.
 */
export function RemoteFetchDialog({ serverUuid, directory, onClose, onFetched }: {
    serverUuid: string;
    directory: string;
    onClose: () => void;
    /** Called once the file is on the server, so the file list can show it. */
    onFetched: () => void;
}) {
    const urlId = useId();
    const urlHelpId = useId();
    const nameId = useId();
    const nameHelpId = useId();
    const [url, setUrl] = useState('');
    const [name, setName] = useState('');
    const [starting, setStarting] = useState(false);
    const [startError, setStartError] = useState<unknown>(null);
    const [job, setJob] = useState<string | undefined>(undefined);
    const progress = useExtensionJobProgress(job, { serverUuid });
    const reported = useRef(false);

    const status = progress.data?.status;
    useEffect(() => {
        if (status === 'completed' && !reported.current) {
            reported.current = true;
            onFetched();
        }
    }, [status, onFetched]);

    const trimmed = url.trim();
    const urlOk = isFetchableUrl(trimmed);
    const nameOk = name === '' || isValidFileName(name);
    const canStart = urlOk && nameOk && !starting;
    const following = job !== undefined;

    const start = async () => {
        if (!canStart) {
            return;
        }

        setStarting(true);
        setStartError(null);
        try {
            setJob(await remoteFetch(serverUuid, { url: trimmed, target_directory: relativeDirectory(directory), ...(name === '' ? {} : { filename: name }) }));
        } catch (error) {
            setStartError(error);
        } finally {
            setStarting(false);
        }
    };

    const again = () => {
        reported.current = false;
        setJob(undefined);
        setStartError(null);
    };

    const failed = status === 'failed';
    const lost = following && progress.isError && !progress.data;

    return (
        <Dialog open onClose={onClose} title="Fetch a file from an address" description={`The Panel downloads the file and saves it in ${displayDirectory(directory)} on this server.`}>
            {!following ? (
                <form
                    className="ftr:flex ftr:flex-col ftr:gap-4"
                    onSubmit={(event) => {
                        event.preventDefault();
                        void start();
                    }}
                >
                    {startError !== null ? (
                        <Notice tone="danger" title={describeError(startError).title}>
                            {describeError(startError).body}
                        </Notice>
                    ) : null}

                    <div>
                        <Label htmlFor={urlId}>Address</Label>
                        <Input id={urlId} type="url" inputMode="url" value={url} onChange={(event) => setUrl(event.target.value)} placeholder="https://example.com/world.zip" autoComplete="off" spellCheck={false} aria-invalid={trimmed !== '' && !urlOk ? true : undefined} aria-describedby={urlHelpId} />
                        <p id={urlHelpId} className={`ftr:mt-1 ftr:text-sm ${trimmed !== '' && !urlOk ? 'ftr:text-destructive' : 'ftr:text-foreground/80'}`}>
                            A public http or https address, without a user name or password.
                        </p>
                    </div>

                    <div>
                        <Label htmlFor={nameId}>Save as (optional)</Label>
                        <Input id={nameId} value={name} onChange={(event) => setName(event.target.value)} maxLength={255} placeholder="Taken from the address" autoComplete="off" spellCheck={false} aria-invalid={!nameOk ? true : undefined} aria-describedby={nameHelpId} />
                        <p id={nameHelpId} className={`ftr:mt-1 ftr:text-sm ${!nameOk ? 'ftr:text-destructive' : 'ftr:text-foreground/80'}`}>
                            Letters, digits, dots, hyphens and underscores only. An existing file with this name is replaced.
                        </p>
                    </div>

                    <Dialog.Footer>
                        <Button type="button" color="grey" isSecondary onClick={onClose}>
                            Close
                        </Button>
                        <Button type="submit" disabled={!canStart} isLoading={starting}>
                            {startError !== null ? 'Try again' : 'Fetch file'}
                        </Button>
                    </Dialog.Footer>
                </form>
            ) : null}

            {following && !failed && status !== 'completed' && !lost ? (
                <div className="ftr:flex ftr:flex-col ftr:gap-4">
                    <ProgressBar value={progress.data ? progress.data.percent : null} label="Download progress" />
                    <p role="status" aria-live="polite" className="ftr:text-sm">
                        {progress.data ? stepText(progress.data.percent) : 'Starting…'}
                    </p>
                    <p className="ftr:text-sm ftr:text-foreground/80">This runs on the Panel. You can close this window; the file appears in the list when it is done.</p>
                    <Dialog.Footer>
                        <Button type="button" color="grey" isSecondary onClick={onClose}>
                            Close
                        </Button>
                    </Dialog.Footer>
                </div>
            ) : null}

            {status === 'completed' ? (
                <div className="ftr:flex ftr:flex-col ftr:gap-4">
                    <Notice tone="success" title="The file is on the server">
                        It is in {displayDirectory(directory)}.
                    </Notice>
                    <Dialog.Footer>
                        <Button type="button" onClick={onClose}>
                            Done
                        </Button>
                    </Dialog.Footer>
                </div>
            ) : null}

            {failed ? (
                <div className="ftr:flex ftr:flex-col ftr:gap-4">
                    <Notice tone="danger" title={describeFailure(progress.data?.message ?? '').title}>
                        {describeFailure(progress.data?.message ?? '').body}
                    </Notice>
                    <Dialog.Footer>
                        <Button type="button" color="grey" isSecondary onClick={onClose}>
                            Close
                        </Button>
                        <Button type="button" onClick={again}>
                            Try again
                        </Button>
                    </Dialog.Footer>
                </div>
            ) : null}

            {lost ? (
                <div className="ftr:flex ftr:flex-col ftr:gap-4">
                    <Notice tone="warning" title="Lost track of the download">
                        The Panel no longer reports on it. Look in the file list: if the file is not there, fetch it again.
                    </Notice>
                    <Dialog.Footer>
                        <Button type="button" color="grey" isSecondary onClick={onClose}>
                            Close
                        </Button>
                        <Button type="button" onClick={again}>
                            Fetch again
                        </Button>
                    </Dialog.Footer>
                </div>
            ) : null}
        </Dialog>
    );
}
