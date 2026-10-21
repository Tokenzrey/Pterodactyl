import { describe, expect, it, vi } from 'vitest';
import extension from './index';
import PlayerCountWidget from './PlayerCountWidget';
import { RconInput } from './RconInput';

// What the extension hands the Panel. A form component that is written but never registered shows nothing in the
// admin form, so a server could not be given its RCON settings: nothing else in the tests would notice.

function setup() {
    const forms = { extend: vi.fn() };
    const slots = { register: vi.fn() };
    const screens = { register: vi.fn() };

    extension.setup({ meta: { id: 'player-manager' }, config: {}, slots, screens, forms, columns: { register: vi.fn() }, views: { override: vi.fn() } } as never);

    return { forms, slots, screens };
}

describe('the extension entry', () => {
    it('draws the RCON fields on the admin server form', () => {
        expect(setup().forms.extend).toHaveBeenCalledWith('admin.server', RconInput);
    });

    it('puts the player count above the console (FR-PM12)', () => {
        expect(setup().slots.register).toHaveBeenCalledWith('server.console.before', PlayerCountWidget);
    });

    it('registers the Players screen that extension.json declares (FR-PM11)', () => {
        const { screens } = setup();

        expect(screens.register).toHaveBeenCalledTimes(1);
        expect(screens.register.mock.calls[0][0]).toBe('players');
        expect(typeof screens.register.mock.calls[0][1]).toBe('function');
    });
});
