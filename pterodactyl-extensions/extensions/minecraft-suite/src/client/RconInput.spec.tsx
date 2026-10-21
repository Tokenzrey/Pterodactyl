import { fireEvent, screen } from '@testing-library/react';
import type { FormExtensionProps } from '@pterodactyl/sdk';
import { useState } from 'react';
import { describe, expect, it } from 'vitest';
import { MASK, RconInput, type RconValues } from './RconInput';
import { renderInPanel, usePanelHost } from './test-utils';

// The admin server form: the fields of RconFields (src/Fields) have to be drawn by the extension itself, or an
// administrator has no way to give a server its RCON host, port and password.

usePanelHost();

type Props = FormExtensionProps<RconValues, 'admin.server'>;
let latest: RconValues;

const DEFAULTS: RconValues = { rcon_host: '', rcon_port: null, rcon_password: '', tps_command: 'spark tps', poll_interval: 10000, cache_seconds: 3 };

function Harness({ initial = {}, errors = {} }: { initial?: Partial<RconValues>; errors?: Partial<Record<keyof RconValues, string>> }) {
    const [values, setValues] = useState<RconValues>({ ...DEFAULTS, ...initial });
    latest = values;

    const field = ((name: keyof RconValues & string) => ({
        id: `mcs-${name}`,
        name: `extensions.minecraft-suite.${name}`,
        value: values[name],
        setValue: (value: string | number | null) => setValues((previous) => ({ ...previous, [name]: value })),
        error: errors[name],
    })) as unknown as Props['field'];

    return <RconInput form="admin.server" mode="edit" values={values} field={field} />;
}

describe('the RCON fields of the admin server form', () => {
    it('labels every field and shows what is saved', async () => {
        await renderInPanel(<Harness initial={{ rcon_host: '127.0.0.1', rcon_port: 25575, tps_command: 'tps', poll_interval: 15000, cache_seconds: 5 }} />);

        expect((screen.getByLabelText('RCON host') as HTMLInputElement).value).toBe('127.0.0.1');
        expect((screen.getByLabelText('RCON port') as HTMLInputElement).value).toBe('25575');
        expect((screen.getByLabelText('TPS command') as HTMLInputElement).value).toBe('tps');
        expect((screen.getByLabelText('Refresh every (ms)') as HTMLInputElement).value).toBe('15000');
        expect((screen.getByLabelText('Cache answers for (seconds)') as HTMLInputElement).value).toBe('5');
        expect(screen.getByRole('heading', { name: 'Minecraft Suite: RCON' })).toBeTruthy();
    });

    it('writes what is typed into the form values', async () => {
        await renderInPanel(<Harness />);

        fireEvent.change(screen.getByLabelText('RCON host'), { target: { value: 'mc.example.com' } });
        fireEvent.change(screen.getByLabelText('RCON password'), { target: { value: 'hunter2' } });
        fireEvent.change(screen.getByLabelText('TPS command'), { target: { value: 'tps' } });

        expect(latest.rcon_host).toBe('mc.example.com');
        expect(latest.rcon_password).toBe('hunter2');
        expect(latest.tps_command).toBe('tps');
    });

    it('turns number inputs into numbers, and an empty one into null', async () => {
        await renderInPanel(<Harness initial={{ rcon_port: 25575 }} />);

        fireEvent.change(screen.getByLabelText('RCON port'), { target: { value: '25576' } });
        expect(latest.rcon_port).toBe(25576);

        fireEvent.change(screen.getByLabelText('RCON port'), { target: { value: '' } });
        expect(latest.rcon_port).toBeNull();
    });

    it('hides the password as it is typed and does not let the browser fill it in', async () => {
        await renderInPanel(<Harness />);

        const password = screen.getByLabelText('RCON password') as HTMLInputElement;

        expect(password.type).toBe('password');
        expect(password.getAttribute('autocomplete')).toBe('new-password');
    });

    it('says when a password is already saved, and that leaving the field keeps it', async () => {
        await renderInPanel(<Harness initial={{ rcon_password: MASK }} />);

        expect(screen.getByText(/A password is saved/)).toBeTruthy();
        expect(screen.getByText(/keep it/)).toBeTruthy();
    });

    it('says when no password is saved yet', async () => {
        await renderInPanel(<Harness />);

        expect(screen.getByText(/No password is saved yet/)).toBeTruthy();
    });

    it('shows the validation message of a field beside it, without a code', async () => {
        await renderInPanel(<Harness errors={{ rcon_host: 'Use an IPv4 address, an IPv6 address or a host name, without a scheme or a path.' }} />);

        expect(screen.getByRole('alert').textContent).toMatch(/without a scheme or a path/);
        expect(screen.getByLabelText('RCON host').getAttribute('aria-invalid')).toBe('true');
    });

    it('explains the port is not the game port, so the wrong one is not entered', async () => {
        await renderInPanel(<Harness />);

        expect(screen.getByText(/Not the game port/)).toBeTruthy();
    });
});
