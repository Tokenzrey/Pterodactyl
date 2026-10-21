import { describe, it, expect } from 'vitest';
import {
    isS3ConfigResponse,
    isPresignResponse,
    isMigration,
    isMigrationListResponse,
    isCreateMigrationResponse,
    isConfirmMigrationResponse,
} from './api';

describe('isS3ConfigResponse', () => {
    it('accepts a valid config response', () => {
        expect(isS3ConfigResponse({
            configured: true,
            endpoint: 'https://s3.amazonaws.com',
            region: 'us-east-1',
            bucket: 'my-bucket',
        })).toBe(true);
    });

    it('accepts a response with null endpoint and bucket', () => {
        expect(isS3ConfigResponse({
            configured: false,
            endpoint: null,
            region: 'us-east-1',
            bucket: null,
        })).toBe(true);
    });

    it('rejects missing configured', () => {
        expect(isS3ConfigResponse({ region: 'us-east-1' })).toBe(false);
    });

    it('rejects null', () => {
        expect(isS3ConfigResponse(null)).toBe(false);
    });
});

describe('isPresignResponse', () => {
    it('accepts a valid presign response', () => {
        expect(isPresignResponse({
            url: 'https://s3.amazonaws.com/bucket/key?X-Amz-Signature=abc',
            method: 'PUT',
            expires_at: '2026-01-01T12:15:00Z',
            object_key: 'migrations/backup.zip',
        })).toBe(true);
    });

    it('rejects missing url', () => {
        expect(isPresignResponse({ method: 'PUT', expires_at: '2026', object_key: 'key' })).toBe(false);
    });

    it('rejects arrays', () => {
        expect(isPresignResponse([])).toBe(false);
    });
});

describe('isMigration', () => {
    it('accepts a valid migration object', () => {
        expect(isMigration({
            id: 1,
            source_server_id: 10,
            source_server_uuid: '550e8400-e29b-41d4-a716-446655440000',
            target_node_id: 20,
            target_allocation_id: 30,
            status: 'pending',
            progress: 0,
            job_id: null,
            last_error: null,
            created_at: '2026-01-01T00:00:00Z',
            updated_at: '2026-01-01T00:00:00Z',
        })).toBe(true);
    });

    it('rejects missing id', () => {
        expect(isMigration({
            source_server_id: 10,
            source_server_uuid: 'uuid',
            target_node_id: 20,
            target_allocation_id: 30,
            status: 'pending',
            progress: 0,
        })).toBe(false);
    });

    it('rejects null', () => {
        expect(isMigration(null)).toBe(false);
    });
});

describe('isMigrationListResponse', () => {
    it('accepts a valid list response', () => {
        expect(isMigrationListResponse({ migrations: [] })).toBe(true);
    });

    it('rejects non-array migrations', () => {
        expect(isMigrationListResponse({ migrations: 'not array' })).toBe(false);
    });
});

describe('isCreateMigrationResponse', () => {
    it('accepts a valid response', () => {
        expect(isCreateMigrationResponse({ migration_id: 1, status: 'pending' })).toBe(true);
    });

    it('rejects missing status', () => {
        expect(isCreateMigrationResponse({ migration_id: 1 })).toBe(false);
    });
});

describe('isConfirmMigrationResponse', () => {
    it('accepts a valid response', () => {
        expect(isConfirmMigrationResponse({ migration_id: 1, status: 'running', job_id: 'abc-123' })).toBe(true);
    });

    it('rejects missing job_id', () => {
        expect(isConfirmMigrationResponse({ migration_id: 1, status: 'running' })).toBe(false);
    });
});
