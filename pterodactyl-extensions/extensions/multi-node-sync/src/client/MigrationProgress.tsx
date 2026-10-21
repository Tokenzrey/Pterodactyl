import { useQuery } from '@tanstack/react-query';
import type { ReactElement } from 'react';
import { getMigration, type Migration } from './api';

/** The statuses a migration does not leave on its own. Polling stops once one of them is reached. */
const FINISHED = ['completed', 'failed', 'cancelled'];
const POLL_MS = 1500;

/** What each error code the job stores means, in words. A code missing here shows the general message. */
const REASONS: Record<string, string> = {
    source_unavailable: 'The server to move no longer exists on the Panel.',
    target_unavailable: 'The Panel could not transfer the server to the target node. Check that the node is online and has room, then try again.',
    no_admin: 'There is no root administrator to run the transfer. Ask the Panel owner to restore one.',
};
const GENERAL = 'Something unexpected went wrong. Ask an administrator to check the Panel log.';

export function reasonText(code: string | null): string {
    return code !== null && Object.hasOwn(REASONS, code) ? REASONS[code] : GENERAL;
}

/**
 * Follows one migration until it finishes. Reads the migration's own record, which the job updates as it goes; the
 * extension's job progress is not used, because this job does not publish to it.
 */
export function MigrationProgress({ migrationId, onBack }: { migrationId: number; onBack: () => void }): ReactElement {
    const migration = useQuery<Migration>({
        queryKey: ['multi-node-sync', 'migration', migrationId],
        queryFn: ({ signal }) => getMigration(migrationId, signal),
        refetchInterval: (query) => (query.state.error || (query.state.data && FINISHED.includes(query.state.data.status)) ? false : POLL_MS),
    });

    if (migration.isError) {
        return (
            <div className="mns:screen">
                <p role="alert" className="mns:error">
                    The migration could not be read. Check the list of migrations to see where it stands.
                </p>
                <button className="mns:btn" onClick={onBack}>
                    Back to migrations
                </button>
            </div>
        );
    }

    const data = migration.data;
    if (!data) {
        return (
            <div className="mns:progress" role="status" aria-live="polite">
                <p>Starting…</p>
            </div>
        );
    }

    const finished = FINISHED.includes(data.status);

    return (
        <div className="mns:screen">
            <h1>Migration #{data.id}</h1>

            {data.status === 'completed' && (
                <div className="mns:progress mns:completed" role="status">
                    <p>Migration completed successfully.</p>
                </div>
            )}
            {data.status === 'failed' && (
                <div className="mns:progress mns:failed" role="alert">
                    <p>{reasonText(data.last_error)}</p>
                </div>
            )}
            {data.status === 'cancelled' && (
                <div className="mns:progress" role="status">
                    <p>The migration was cancelled.</p>
                </div>
            )}
            {!finished && (
                <div className="mns:progress" role="status" aria-live="polite">
                    <p>Migrating… {data.progress}%</p>
                    <progress value={data.progress} max={100} aria-label={`Migration #${data.id} progress`} />
                </div>
            )}

            {finished && (
                <button className="mns:btn mns:btn-primary" onClick={onBack}>
                    Back to migrations
                </button>
            )}
        </div>
    );
}
