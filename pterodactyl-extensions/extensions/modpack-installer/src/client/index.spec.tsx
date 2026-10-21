import { describe, expect, it, vi } from 'vitest';
import extension from './index';

// A screen that is written but never registered is not in the Panel's menu, and no other test would notice.

function setup() {
    const slots = { register: vi.fn() };
    const screens = { register: vi.fn() };
    const forms = { extend: vi.fn() };

    extension.setup({ meta: { id: 'modpack-installer' }, config: {}, slots, screens, forms, columns: { register: vi.fn() }, views: { override: vi.fn() } } as never);

    return { slots, screens, forms };
}

describe('the extension entry', () => {
    it('registers the screen that extension.json declares (FR-MI12)', () => {
        const { screens } = setup();

        expect(screens.register).toHaveBeenCalledTimes(1);
        expect(screens.register.mock.calls[0][0]).toBe('modpacks');
        expect(typeof screens.register.mock.calls[0][1]).toBe('function');
    });

    it('registers nothing else: no slot, no form', () => {
        const { slots, forms } = setup();

        expect(slots.register).not.toHaveBeenCalled();
        expect(forms.extend).not.toHaveBeenCalled();
    });
});
