/**
 * The folder the file manager is showing, as the backend wants it: relative to the server's root, with "." for the
 * root itself. The file manager says "/" or "/plugins/Essentials"; the backend refuses a path that starts with "/".
 */
export function relativeDirectory(directory: string): string {
    const segments = directory.split('/').filter((segment) => segment !== '' && segment !== '.');

    return segments.length === 0 ? '.' : segments.join('/');
}

/** The folder as a person reads it: "/" or "/plugins". */
export function displayDirectory(directory: string): string {
    const relative = relativeDirectory(directory);

    return relative === '.' ? '/' : `/${relative}`;
}

/** The rule the backend applies to a file name: 1 to 255 letters, digits, "_", "-" and ".", and not dots alone. */
export function isValidFileName(name: string): boolean {
    return name.length >= 1 && name.length <= 255 && /^[A-Za-z0-9_.-]+$/.test(name) && name.replaceAll('.', '') !== '';
}

/** A name the backend will take, made from a file's own: anything else becomes "_". Empty when nothing usable is left. */
export function suggestFileName(name: string): string {
    const safe = name.replaceAll(/[^A-Za-z0-9_.-]/g, '_').slice(0, 255);

    return isValidFileName(safe) ? safe : '';
}

/** An address the Panel could fetch, as far as the browser can tell: http or https, no user name or password. The server decides the rest. */
export function isFetchableUrl(value: string): boolean {
    try {
        const url = new URL(value);

        return (url.protocol === 'http:' || url.protocol === 'https:') && url.username === '' && url.password === '' && url.hostname !== '';
    } catch {
        return false;
    }
}

export function formatBytes(bytes: number): string {
    if (bytes < 1024) {
        return `${bytes} B`;
    }

    const units = ['KB', 'MB', 'GB', 'TB'];
    let value = bytes / 1024;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }

    return `${value >= 100 ? Math.round(value) : Number(value.toFixed(1))} ${units[unit]}`;
}
