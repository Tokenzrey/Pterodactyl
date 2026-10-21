import { Button, ProgressBar, useExtensionJobProgress } from '@pterodactyl/sdk';
import { describeFailure } from './api';
import { Notice } from './Notice';

/** The Panel moves to "handing over" at 50 percent and to "unpacking" at 80, as the spec's stages do (FR-MI10). */
export function stepText(percent: number): string {
    if (percent < 50) {
        return 'Downloading the server pack…';
    }
    if (percent < 80) {
        return 'Sending it to the server…';
    }
    if (percent < 95) {
        return 'Unpacking it…';
    }

    return 'Removing launch scripts that clash with the server’s own…';
}

/**
 * Follows the install's progress record until it ends. The work happens on the Panel, so closing the page does not stop
 * it. Every way it can end is said in words, with a way back to the search.
 */
export function InstallProgress({ jobId, serverUuid, name, onDone }: { jobId: string; serverUuid: string; name: string; onDone: () => void }) {
    const progress = useExtensionJobProgress(jobId, { serverUuid });
    const snapshot = progress.data;

    if (snapshot?.status === 'completed') {
        return (
            <div className="mki:flex mki:flex-col mki:items-start mki:gap-4">
                <Notice tone="success" title={`${name} is installed`}>
                    The files are on the server. Restart the server to use them.
                </Notice>
                <Button type="button" onClick={onDone}>
                    Install another
                </Button>
            </div>
        );
    }

    if (snapshot?.status === 'failed') {
        const reason = describeFailure(snapshot.message);

        return (
            <div className="mki:flex mki:flex-col mki:items-start mki:gap-4">
                <Notice tone="danger" title={reason.title}>
                    {reason.body}
                </Notice>
                <Button type="button" color="grey" isSecondary onClick={onDone}>
                    Back to the search
                </Button>
            </div>
        );
    }

    // No record to read: it has expired, or was never made. The install may still have worked.
    if (progress.isError) {
        return (
            <div className="mki:flex mki:flex-col mki:items-start mki:gap-4">
                <Notice tone="warning" title="Lost track of the installation">
                    The Panel no longer reports on it. Look at the server&rsquo;s files: if the pack is not there, install it again.
                </Notice>
                <Button type="button" color="grey" isSecondary onClick={onDone}>
                    Back to the search
                </Button>
            </div>
        );
    }

    const percent = snapshot?.percent ?? 0;

    return (
        <div className="mki:flex mki:flex-col mki:gap-4">
            <h2 className="mki:text-lg mki:font-medium">Installing {name}</h2>
            <ProgressBar value={percent} label={`Installing ${name}`} />
            <p role="status" aria-live="polite" className="mki:text-sm">
                {snapshot ? stepText(percent) : 'Starting…'}
            </p>
            <p className="mki:text-sm mki:text-foreground/80">This runs on the Panel. You can leave this page; the files appear on the server when it is done.</p>
        </div>
    );
}
