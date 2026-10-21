import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { fireEvent, render, screen, cleanup } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi, afterEach } from 'vitest';
import { getMigration, type Migration } from './api';
import { MigrationProgress, reasonText } from './MigrationProgress';

afterEach(() => cleanup());

vi.mock('./api', () => ({ getMigration: vi.fn() }));

const migration = (overrides: Partial<Migration> = {}): Migration => ({
    id: 7,
    source_server_id: 1,
    source_server_uuid: '11111111-2222-4333-8444-555555555555',
    target_node_id: 2,
    target_allocation_id: 30,
    status: 'running',
    progress: 40,
    job_id: null,
    last_error: null,
    created_at: null,
    updated_at: null,
    ...overrides,
});

function renderProgress(onBack = vi.fn()) {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    return {
        onBack,
        ...render(
            <QueryClientProvider client={client}>
                <MigrationProgress migrationId={7} onBack={onBack} />
            </QueryClientProvider>,
        ),
    };
}

beforeEach(() => {
    vi.mocked(getMigration).mockReset();
});

describe('MigrationProgress', () => {
    it('shows how far a running migration has got, as a labelled progress bar', async () => {
        vi.mocked(getMigration).mockResolvedValue(migration({ status: 'running', progress: 40 }));
        renderProgress();

        expect(await screen.findByText('Migrating… 40%')).toBeTruthy();
        expect((screen.getByRole('progressbar', { name: 'Migration #7 progress' }) as HTMLProgressElement).value).toBe(40);
        expect(screen.queryByRole('button', { name: 'Back to migrations' })).toBeNull();
    });

    it('says so when the migration completed, and offers a way back', async () => {
        vi.mocked(getMigration).mockResolvedValue(migration({ status: 'completed', progress: 100 }));
        const { onBack } = renderProgress();

        expect(await screen.findByText('Migration completed successfully.')).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: 'Back to migrations' }));
        expect(onBack).toHaveBeenCalledTimes(1);
    });

    it('explains a failure in words, never with the code the job stored', async () => {
        vi.mocked(getMigration).mockResolvedValue(migration({ status: 'failed', last_error: 'source_unavailable' }));
        renderProgress();

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain('The server to move no longer exists on the Panel.');
        expect(alert.textContent).not.toContain('source_unavailable');
    });

    it('falls back to the general message for a code it does not know', async () => {
        vi.mocked(getMigration).mockResolvedValue(migration({ status: 'failed', last_error: 'something_new' }));
        renderProgress();

        expect((await screen.findByRole('alert')).textContent).toContain('Something unexpected went wrong.');
    });

    it('says a cancelled migration was cancelled', async () => {
        vi.mocked(getMigration).mockResolvedValue(migration({ status: 'cancelled', progress: 0 }));
        renderProgress();

        expect(await screen.findByText('The migration was cancelled.')).toBeTruthy();
    });

    it('says it could not read the migration, instead of showing a stale or empty state', async () => {
        vi.mocked(getMigration).mockRejectedValue(new Error('Network Error'));
        renderProgress();

        expect((await screen.findByRole('alert')).textContent).toContain('The migration could not be read.');
        expect(screen.getByRole('button', { name: 'Back to migrations' })).toBeTruthy();
    });

    it('shows a starting state until the first answer arrives', () => {
        vi.mocked(getMigration).mockReturnValue(new Promise(() => {}));
        renderProgress();

        expect(screen.getByText('Starting…')).toBeTruthy();
    });
});

describe('reasonText', () => {
    it.each([
        ['source_unavailable', 'no longer exists'],
        ['target_unavailable', 'could not transfer the server'],
        ['no_admin', 'no root administrator'],
    ])('explains %s', (code, words) => {
        expect(reasonText(code)).toContain(words);
    });

    it('gives the general message for no code, for an unknown one, and for a code of the old design', () => {
        expect(reasonText(null)).toContain('Something unexpected went wrong.');
        expect(reasonText('constructor')).toContain('Something unexpected went wrong.');
        expect(reasonText('backup_failed')).toContain('Something unexpected went wrong.');
    });
});
