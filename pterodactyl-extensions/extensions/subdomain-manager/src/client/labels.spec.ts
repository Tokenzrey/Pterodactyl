import { describe, expect, it } from 'vitest';
import { fqdn, labelProblem } from './labels';

// Mirrors tests/Unit/LabelsTest.php: the form and the backend must agree on what a label is.

describe('labelProblem', () => {
    it.each(['kampung', 'a', '1a', '123', 'my-server', 'xn--bcher-kva', 'a'.repeat(63)])('accepts %s', (label) => {
        expect(labelProblem(label, [])).toBeNull();
    });

    it.each(['Kampung', 'a_b', 'a.b', '-a', 'a-', '-', 'a b', ' a', 'a ', 'a'.repeat(64), 'kämpung', '*', '_minecraft', '../x'])('calls %j invalid', (label) => {
        expect(labelProblem(label, [])).toBe('invalid');
    });

    it('treats the empty label as "no subdomain", not a problem', () => {
        expect(labelProblem('', ['www'])).toBeNull();
    });

    it('knows reserved names whatever case the list was typed in', () => {
        expect(labelProblem('www', ['www'])).toBe('reserved');
        expect(labelProblem('mail', ['WWW', 'Mail'])).toBe('reserved');
        expect(labelProblem('kampung', ['www'])).toBeNull();
    });

    it('does not accept a trailing newline', () => {
        expect(labelProblem('a\n', [])).toBe('invalid');
    });
});

describe('fqdn', () => {
    it('joins label and domain in lower case', () => {
        expect(fqdn('kampung', 'MC.Example.com')).toBe('kampung.mc.example.com');
    });
});
