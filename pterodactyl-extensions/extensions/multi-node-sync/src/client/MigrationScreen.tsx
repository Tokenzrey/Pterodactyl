import { useCallback, useEffect, useState } from 'react';
import {
    createMigration,
    confirmMigration,
    listMigrations,
    cancelMigration,
    type Migration,
} from './api';
import { MigrationProgress } from './MigrationProgress';

export default function MigrationScreen(): React.ReactElement {
    const [migrations, setMigrations] = useState<Migration[]>([]);
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [activeMigrationId, setActiveMigrationId] = useState<number | null>(null);

    const [sourceServerId, setSourceServerId] = useState('');
    const [targetNodeId, setTargetNodeId] = useState('');
    const [targetAllocationId, setTargetAllocationId] = useState('');
    const [serverNameConfirmation, setServerNameConfirmation] = useState('');
    const [pendingMigrationId, setPendingMigrationId] = useState<number | null>(null);

    const refreshMigrations = useCallback(async () => {
        setLoading(true);
        try {
            const response = await listMigrations();
            setMigrations(response.migrations);
        } catch {
            setError('Failed to load migrations.');
        } finally {
            setLoading(false);
        }
    }, []);

    useEffect(() => {
        refreshMigrations();
    }, [refreshMigrations]);

    const handleCreate = useCallback(async () => {
        setError(null);
        try {
            const response = await createMigration({
                source_server_id: Number(sourceServerId),
                target_node_id: Number(targetNodeId),
                target_allocation_id: Number(targetAllocationId),
            });
            setPendingMigrationId(response.migration_id);
            await refreshMigrations();
        } catch (e) {
            setError(e instanceof Error ? e.message : 'Failed to create migration.');
        }
    }, [sourceServerId, targetNodeId, targetAllocationId, refreshMigrations]);

    const handleConfirm = useCallback(async () => {
        if (pendingMigrationId === null) return;
        setError(null);
        try {
            const response = await confirmMigration(pendingMigrationId, {
                server_name_confirmation: serverNameConfirmation,
            });
            setActiveMigrationId(response.migration_id);
            await refreshMigrations();
        } catch (e) {
            setError(e instanceof Error ? e.message : 'Failed to confirm migration.');
        }
    }, [pendingMigrationId, serverNameConfirmation, refreshMigrations]);

    const handleCancel = useCallback(async (id: number) => {
        setError(null);
        try {
            await cancelMigration(id);
            await refreshMigrations();
        } catch (e) {
            setError(e instanceof Error ? e.message : 'Failed to cancel migration.');
        }
    }, [refreshMigrations]);

    if (activeMigrationId !== null) {
        return (
            <MigrationProgress
                migrationId={activeMigrationId}
                onBack={() => {
                    setActiveMigrationId(null);
                    setPendingMigrationId(null);
                    setServerNameConfirmation('');
                    refreshMigrations();
                }}
            />
        );
    }

    return (
        <div className="mns:screen">
            <h1>Server Migration</h1>
            {error !== null && <div className="mns:error">{error}</div>}
            <div className="mns:form">
                <div className="mns:form-row">
                    <label>Source Server ID</label>
                    <input type="number" value={sourceServerId} onChange={(e) => setSourceServerId(e.target.value)} placeholder="Server ID" />
                </div>
                <div className="mns:form-row">
                    <label>Target Node ID</label>
                    <input type="number" value={targetNodeId} onChange={(e) => setTargetNodeId(e.target.value)} placeholder="Node ID" />
                </div>
                <div className="mns:form-row">
                    <label>Target Allocation ID</label>
                    <input type="number" value={targetAllocationId} onChange={(e) => setTargetAllocationId(e.target.value)} placeholder="Allocation ID on target node" />
                </div>
                <button className="mns:btn mns:btn-primary" onClick={handleCreate} disabled={!sourceServerId || !targetNodeId || !targetAllocationId}>
                    Create Migration
                </button>
            </div>

            {pendingMigrationId !== null && (
                <div className="mns:form">
                    <h2>Confirm Migration #{pendingMigrationId}</h2>
                    <p>Type the server name exactly to confirm:</p>
                    <div className="mns:form-row">
                        <label>Server Name</label>
                        <input type="text" value={serverNameConfirmation} onChange={(e) => setServerNameConfirmation(e.target.value)} />
                    </div>
                    <button className="mns:btn mns:btn-primary" onClick={handleConfirm} disabled={!serverNameConfirmation}>
                        Confirm & Start
                    </button>
                </div>
            )}

            <div className="mns:migration-list">
                <h2>Migrations</h2>
                {loading && <div className="mns:loading">Loading...</div>}
                {migrations.map((m) => (
                    <div key={m.id} className="mns:migration-item">
                        <div>
                            <strong>#{m.id}</strong> — Server {m.source_server_id} → Node {m.target_node_id}
                            <span className={`mns:status-${m.status}`}> [{m.status}]</span>
                            {m.status === 'running' && <span> {m.progress}%</span>}
                        </div>
                        <div>
                            {m.status === 'pending' && (
                                <button className="mns:btn mns:btn-danger" onClick={() => handleCancel(m.id)}>
                                    Cancel
                                </button>
                            )}
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );
}
