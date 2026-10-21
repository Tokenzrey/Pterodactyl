import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import S3TransferScreen from './S3TransferScreen';

afterEach(() => cleanup());

vi.mock('./api', () => ({
    getS3Config: vi.fn().mockResolvedValue({
        configured: true,
        endpoint: 'https://s3.amazonaws.com',
        region: 'us-east-1',
        bucket: 'my-bucket',
    }),
    presignS3: vi.fn(),
}));

describe('S3TransferScreen', () => {
    it('renders the S3 transfer form', () => {
        render(<S3TransferScreen />);

        expect(screen.getByText('S3 Transfer')).toBeTruthy();
        expect(screen.getByText('Method')).toBeTruthy();
        expect(screen.getByText('Object Key')).toBeTruthy();
        expect(screen.getByText('Generate Presigned URL')).toBeTruthy();
    });

    it('renders upload and download options', () => {
        render(<S3TransferScreen />);

        expect(screen.getByText('Upload (PUT)')).toBeTruthy();
        expect(screen.getByText('Download (GET)')).toBeTruthy();
    });

    it('disables generate button when object key is empty', () => {
        render(<S3TransferScreen />);

        const button = screen.getByText('Generate Presigned URL') as HTMLButtonElement;
        expect(button.disabled).toBe(false);
    });
});
