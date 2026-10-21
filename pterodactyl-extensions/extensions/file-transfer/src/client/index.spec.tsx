import { describe, expect, it, vi } from 'vitest';
import extension from './index';

// A toolbar that is written but never registered shows nothing in the file manager, and nothing else would notice.

function setup(config: Record<string, unknown>) {
    const slots = { register: vi.fn() };
    const screens = { register: vi.fn() };
    const forms = { extend: vi.fn() };

    extension.setup({ meta: { id: 'file-transfer' }, config, slots, screens, forms, columns: { register: vi.fn() }, views: { override: vi.fn() } } as never);

    return { slots, screens, forms };
}

describe('the extension entry', () => {
    it('puts the toolbar in the file manager', () => {
        const { slots } = setup({});

        expect(slots.register).toHaveBeenCalledTimes(1);
        expect(slots.register.mock.calls[0][0]).toBe('server.files.toolbar');
        expect(typeof slots.register.mock.calls[0][1]).toBe('function');
    });

    it('registers nothing else: no screen, no form', () => {
        const { screens, forms } = setup({ chunk_size_mb: 8, max_file_mb: 100 });

        expect(screens.register).not.toHaveBeenCalled();
        expect(forms.extend).not.toHaveBeenCalled();
    });
});
