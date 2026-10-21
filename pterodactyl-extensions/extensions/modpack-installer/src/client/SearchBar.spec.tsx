import { act, fireEvent, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { DEBOUNCE_MS, SearchBar } from './SearchBar';
import { renderInPanel, usePanelHost } from './test-utils';

// FR-MI15: a search goes out 500 ms after typing stops, and not before.

usePanelHost();

/** Renders the bar on real timers, then switches to fake ones so that the 500 ms can be crossed at once. */
async function open() {
    const onCriteria = vi.fn();
    await renderInPanel(<SearchBar onCriteria={onCriteria} start={{ source: 'curseforge', gameVersion: '', loader: '' }} />, { owner: true });
    vi.useFakeTimers();
    onCriteria.mockClear();

    return {
        onCriteria,
        type: (label: string | RegExp, value: string) => fireEvent.change(screen.getByLabelText(label), { target: { value } }),
        wait: (ms: number) => act(async () => void vi.advanceTimersByTime(ms)),
    };
}

describe('the debounce', () => {
    it('is 500 ms', () => {
        expect(DEBOUNCE_MS).toBe(500);
    });

    it('sends nothing while typing goes on, then one search when it stops', async () => {
        const { onCriteria, type, wait } = await open();

        type('Search modpacks', 'a');
        await wait(300);
        type('Search modpacks', 'at');
        await wait(300);
        type('Search modpacks', 'atm');
        await wait(499);

        expect(onCriteria).not.toHaveBeenCalled();

        await wait(1);

        expect(onCriteria).toHaveBeenCalledTimes(1);
        expect(onCriteria).toHaveBeenCalledWith({ source: 'curseforge', query: 'atm' });
    });

    it('trims the query', async () => {
        const { onCriteria, type, wait } = await open();

        type('Search modpacks', '  atm  ');
        await wait(DEBOUNCE_MS);

        expect(onCriteria).toHaveBeenLastCalledWith({ source: 'curseforge', query: 'atm' });
    });

    it('reports nothing to search for when the query is empty or blank', async () => {
        const { onCriteria, type, wait } = await open();

        type('Search modpacks', 'atm');
        await wait(DEBOUNCE_MS);
        type('Search modpacks', '   ');
        await wait(DEBOUNCE_MS);

        expect(onCriteria).toHaveBeenLastCalledWith(null);
    });
});

describe('the filters', () => {
    it('sends the source, the version and the loader that were chosen', async () => {
        const { onCriteria, type, wait } = await open();

        type('Source', 'modrinth');
        type('Search modpacks', 'fabulous');
        type('Minecraft version', ' 1.20.1 ');
        type('Mod loader', 'fabric');
        await wait(DEBOUNCE_MS);

        expect(onCriteria).toHaveBeenLastCalledWith({ source: 'modrinth', query: 'fabulous', game_version: '1.20.1', loader: 'fabric' });
    });

    it('leaves out a version and a loader that are empty', async () => {
        const { onCriteria, type, wait } = await open();

        type('Search modpacks', 'atm');
        type('Minecraft version', '   ');
        await wait(DEBOUNCE_MS);

        expect(onCriteria).toHaveBeenLastCalledWith({ source: 'curseforge', query: 'atm' });
    });

    it('offers CurseForge first, and the four loaders', async () => {
        await open();

        expect((screen.getByLabelText('Source') as HTMLSelectElement).value).toBe('curseforge');
        expect(Array.from((screen.getByLabelText('Mod loader') as HTMLSelectElement).options).map((option) => option.value)).toEqual(['', 'forge', 'neoforge', 'fabric', 'quilt']);
    });

    it('refuses a version the Panel would refuse: says so, marks the field, and does not search', async () => {
        const { onCriteria, type, wait } = await open();

        type('Search modpacks', 'atm');
        type('Minecraft version', '1.20&gameId=1');
        await wait(DEBOUNCE_MS);

        const field = screen.getByLabelText('Minecraft version');
        expect(onCriteria).toHaveBeenLastCalledWith(null);
        expect(field.getAttribute('aria-invalid')).toBe('true');
        expect(screen.getByText('Use only letters, digits, dots and hyphens.')).toBeTruthy();
    });

    it('warns that CurseForge applies a loader only with a version', async () => {
        const { type } = await open();

        type('Mod loader', 'forge');
        expect(screen.getByText(/only together with a Minecraft version/)).toBeTruthy();

        type('Minecraft version', '1.20.1');
        expect(screen.queryByText(/only together with a Minecraft version/)).toBeNull();
    });

    it('does not give that warning for Modrinth, which applies a loader alone', async () => {
        const { type } = await open();

        type('Source', 'modrinth');
        type('Mod loader', 'forge');

        expect(screen.queryByText(/only together with a Minecraft version/)).toBeNull();
    });
});

describe('access', () => {
    it('is a search landmark with every field labelled', async () => {
        await open();

        expect(screen.getByRole('search')).toBeTruthy();
        for (const label of ['Source', 'Search modpacks', 'Minecraft version', 'Mod loader']) {
            expect(screen.getByLabelText(label)).toBeTruthy();
        }
    });

    it('does not reload the page when Enter is pressed', async () => {
        await open();

        const allowed = fireEvent.submit(screen.getByRole('search'));

        expect(allowed).toBe(false);
    });
});

describe('starting from the saved defaults', () => {
    it('shows the source, version and loader it was given', async () => {
        const onCriteria = vi.fn();
        await renderInPanel(<SearchBar onCriteria={onCriteria} start={{ source: 'curseforge', gameVersion: '1.20.1', loader: 'fabric' }} />, { owner: true });

        expect((screen.getByLabelText('Minecraft version') as HTMLInputElement).value).toBe('1.20.1');
        expect((screen.getByLabelText('Mod loader') as HTMLSelectElement).value).toBe('fabric');
    });
});

describe('saving the choices as the defaults', () => {
    it('is offered only when there is something to save to', async () => {
        await open();

        expect(screen.queryByRole('button', { name: /Save these as the defaults/ })).toBeNull();
    });

    it('hands over what is on the form, with the version trimmed', async () => {
        const onSaveDefaults = vi.fn();
        await renderInPanel(<SearchBar onCriteria={vi.fn()} start={{ source: 'curseforge', gameVersion: '', loader: '' }} onSaveDefaults={onSaveDefaults} />, { owner: true });

        fireEvent.change(screen.getByLabelText('Minecraft version'), { target: { value: ' 1.21 ' } });
        fireEvent.change(screen.getByLabelText('Mod loader'), { target: { value: 'quilt' } });
        fireEvent.click(screen.getByRole('button', { name: /Save these as the defaults/ }));

        expect(onSaveDefaults).toHaveBeenCalledWith({ default_source: 'curseforge', default_game_version: '1.21', default_loader: 'quilt' });
    });

    it('cannot be saved with a version the Panel would refuse', async () => {
        await renderInPanel(<SearchBar onCriteria={vi.fn()} start={{ source: 'curseforge', gameVersion: '', loader: '' }} onSaveDefaults={vi.fn()} />, { owner: true });

        fireEvent.change(screen.getByLabelText('Minecraft version'), { target: { value: '1 20' } });

        expect((screen.getByRole('button', { name: /Save these as the defaults/ }) as HTMLButtonElement).disabled).toBe(true);
    });
});

