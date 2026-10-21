import { http } from '@pterodactyl/sdk';

const BASE = '/api/admin/extensions/multi-node-sync';

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
const isString = (value: unknown): value is string => typeof value === 'string';
const isNumber = (value: unknown): value is number => typeof value === 'number';
const isBoolean = (value: unknown): value is boolean => typeof value === 'boolean';
const unexpected = (what: string) => new Error(`The ${what} has an unexpected shape.`);

export interface S3ConfigResponse {
    configured: boolean;
    endpoint: string | null;
    region: string;
    bucket: string | null;
}

export const isS3ConfigResponse = (value: unknown): value is S3ConfigResponse =>
    isObject(value) && isBoolean(value.configured) && isString(value.region);

export interface PresignResponse {
    url: string;
    method: string;
    expires_at: string;
    object_key: string;
}

export const isPresignResponse = (value: unknown): value is PresignResponse =>
    isObject(value) && isString(value.url) && isString(value.method) && isString(value.expires_at) && isString(value.object_key);

export interface Migration {
    id: number;
    source_server_id: number;
    source_server_uuid: string;
    target_node_id: number;
    target_allocation_id: number;
    status: string;
    progress: number;
    job_id: string | null;
    last_error: string | null;
    created_at: string | null;
    updated_at: string | null;
}

export const isMigration = (value: unknown): value is Migration =>
    isObject(value) && isNumber(value.id) && isNumber(value.source_server_id) && isString(value.source_server_uuid) && isNumber(value.target_node_id) && isNumber(value.target_allocation_id) && isString(value.status) && isNumber(value.progress);

export interface MigrationListResponse {
    migrations: Migration[];
}

export const isMigrationListResponse = (value: unknown): value is MigrationListResponse =>
    isObject(value) && Array.isArray(value.migrations);

export interface CreateMigrationBody {
    source_server_id: number;
    target_node_id: number;
    target_allocation_id: number;
}

export interface CreateMigrationResponse {
    migration_id: number;
    status: string;
}

export const isCreateMigrationResponse = (value: unknown): value is CreateMigrationResponse =>
    isObject(value) && isNumber(value.migration_id) && isString(value.status);

export interface ConfirmMigrationBody {
    server_name_confirmation: string;
}

export interface ConfirmMigrationResponse {
    migration_id: number;
    status: string;
    job_id: string;
}

export const isConfirmMigrationResponse = (value: unknown): value is ConfirmMigrationResponse =>
    isObject(value) && isNumber(value.migration_id) && isString(value.status) && isString(value.job_id);

export async function getS3Config(signal?: AbortSignal): Promise<S3ConfigResponse> {
    const { data } = await http.get<unknown>(`${BASE}/s3/config`, { signal });

    if (!isS3ConfigResponse(data)) {
        throw unexpected('S3 config response');
    }

    return data;
}

export async function presignS3(body: { method: 'GET' | 'PUT'; object_key: string }): Promise<PresignResponse> {
    const { data } = await http.post<unknown>(`${BASE}/s3/presign`, body);

    if (!isPresignResponse(data)) {
        throw unexpected('presign response');
    }

    return data;
}

export async function createMigration(body: CreateMigrationBody): Promise<CreateMigrationResponse> {
    const { data } = await http.post<unknown>(`${BASE}/migrations`, body);

    if (!isCreateMigrationResponse(data)) {
        throw unexpected('create migration response');
    }

    return data;
}

export async function confirmMigration(id: number, body: ConfirmMigrationBody): Promise<ConfirmMigrationResponse> {
    const { data } = await http.post<unknown>(`${BASE}/migrations/${id}/confirm`, body);

    if (!isConfirmMigrationResponse(data)) {
        throw unexpected('confirm migration response');
    }

    return data;
}

export async function listMigrations(signal?: AbortSignal): Promise<MigrationListResponse> {
    const { data } = await http.get<unknown>(`${BASE}/migrations`, { signal });

    if (!isMigrationListResponse(data)) {
        throw unexpected('migration list response');
    }

    return { migrations: data.migrations.filter(isMigration) };
}

export async function getMigration(id: number, signal?: AbortSignal): Promise<Migration> {
    const { data } = await http.get<unknown>(`${BASE}/migrations/${id}`, { signal });

    if (!isMigration(data)) {
        throw unexpected('migration response');
    }

    return data;
}

export async function cancelMigration(id: number): Promise<{ migration_id: number; status: string }> {
    const { data } = await http.delete<unknown>(`${BASE}/migrations/${id}`);

    if (!isObject(data) || !isNumber(data.migration_id) || !isString(data.status)) {
        throw unexpected('cancel migration response');
    }

    return { migration_id: data.migration_id, status: data.status };
}
