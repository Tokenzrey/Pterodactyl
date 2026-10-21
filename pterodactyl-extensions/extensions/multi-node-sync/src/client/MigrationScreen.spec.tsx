import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import MigrationScreen from './MigrationScreen';

afterEach(() => cleanup());

vi.mock('./api', () => ({
    createMigration: vi.fn(),
    confirmMigration: vi.fn(),
    listMigrations: vi.fn().mockResolvedValue({ migrations: [] }),
    cancelMigration: vi.fn(),
}));

vi.mock('./MigrationProgress', () => ({
    MigrationProgress: () => <div data-testid="migration-progress">Progress</div>,
}));

describe('MigrationScreen', () => {
    it('renders the migration form', () => {
        render(<MigrationScreen />);

        expect(screen.getByText('Server Migration')).toBeTruthy();
        expect(screen.getByText('Source Server ID')).toBeTruthy();
        expect(screen.getByText('Target Node ID')).toBeTruthy();
        expect(screen.getByText('Target Allocation ID')).toBeTruthy();
        expect(screen.queryByText('Keep Source Files')).toBeNull();
        expect(screen.getByText('Create Migration')).toBeTruthy();
    });

    it('renders the migrations list section', () => {
        render(<MigrationScreen />);

        expect(screen.getByText('Migrations')).toBeTruthy();
    });

    it('disables create button when fields are empty', () => {
        render(<MigrationScreen />);

        const button = screen.getByText('Create Migration') as HTMLButtonElement;
        expect(button.disabled).toBe(true);
    });
});
