import { fireEvent, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { PlayerAvatars } from './PlayerAvatars';
import { renderInPanel, usePanelHost } from './test-utils';

// AC-MS15, FR-MS11, EC-MS7, EC-MS8: an image for a valid UUID, a letter for the rest, and a letter again if the image fails.

usePanelHost();

const STEVE = '069a79f4-44e9-4726-a5be-fca90e38aaf5';

describe('PlayerAvatars', () => {
    it('draws a lazy Crafatar image for a valid UUID and a letter for null (AC-MS15)', async () => {
        await renderInPanel(
            <PlayerAvatars
                players={[
                    { name: 'Steve', uuid: STEVE },
                    { name: 'Alex', uuid: null },
                ]}
            />,
        );

        const image = screen.getByAltText('Steve') as HTMLImageElement;
        expect(image.src).toBe(`https://crafatar.com/avatars/${STEVE}?size=64`);
        expect(image.getAttribute('loading')).toBe('lazy');
        expect(screen.queryByAltText('Alex')).toBeNull();
        expect(screen.getByText('A')).toBeTruthy();
    });

    it('draws no image for a UUID that is not one, however it looks (NFR-MS5)', async () => {
        await renderInPanel(<PlayerAvatars players={[{ name: 'Evil', uuid: '../../evil' }]} />);

        expect(screen.queryByRole('img')).toBeNull();
        expect(screen.getByText('E')).toBeTruthy();
    });

    it('falls back to the letter when Crafatar cannot be reached (EC-MS7)', async () => {
        await renderInPanel(<PlayerAvatars players={[{ name: 'Steve', uuid: STEVE }]} />);

        fireEvent.error(screen.getByAltText('Steve'));

        expect(screen.queryByAltText('Steve')).toBeNull();
        expect(screen.getByText('S')).toBeTruthy();
    });

    it('marks every image as lazy, so fifty players do not load at once (EC-MS8)', async () => {
        const players = Array.from({ length: 50 }, (_, index) => ({ name: `P${index}`, uuid: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}` }));
        await renderInPanel(<PlayerAvatars players={players} />);

        const images = screen.getAllByRole('img');

        expect(images).toHaveLength(50);
        expect(images.every((image) => image.getAttribute('loading') === 'lazy')).toBe(true);
    });
});
