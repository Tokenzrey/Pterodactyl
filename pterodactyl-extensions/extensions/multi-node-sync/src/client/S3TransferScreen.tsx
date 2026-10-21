import { useCallback, useEffect, useState } from 'react';
import { getS3Config, presignS3, type S3ConfigResponse, type PresignResponse } from './api';

export default function S3TransferScreen(): React.ReactElement {
    const [config, setConfig] = useState<S3ConfigResponse | null>(null);
    const [method, setMethod] = useState<'GET' | 'PUT'>('PUT');
    const [objectKey, setObjectKey] = useState('migrations/backup.tar.gz');
    const [result, setResult] = useState<PresignResponse | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);
    const [isExpired, setIsExpired] = useState(false);

    useEffect(() => {
        getS3Config().then(setConfig).catch(() => setError('Failed to load S3 config.'));
    }, []);

    useEffect(() => {
        if (result === null) return;
        const expiry = new Date(result.expires_at).getTime();
        const now = Date.now();
        if (expiry <= now) {
            setIsExpired(true);
            return;
        }
        setIsExpired(false);
        const timer = setTimeout(() => setIsExpired(true), expiry - now);
        return () => clearTimeout(timer);
    }, [result]);

    const handlePresign = useCallback(async () => {
        setError(null);
        setLoading(true);
        try {
            const response = await presignS3({ method, object_key: objectKey });
            setResult(response);
        } catch (e) {
            setError(e instanceof Error ? e.message : 'Failed to generate presigned URL.');
            setResult(null);
        } finally {
            setLoading(false);
        }
    }, [method, objectKey]);

    return (
        <div className="mns:screen">
            <h1>S3 Transfer</h1>
            {error !== null && <div className="mns:error">{error}</div>}

            {config !== null && (
                <div>
                    <p>
                        <strong>Configured:</strong> {config.configured ? 'Yes' : 'No'}
                        {config.endpoint !== null && ` — ${config.endpoint}`}
                        {config.bucket !== null && ` / ${config.bucket}`}
                    </p>
                </div>
            )}

            <div className="mns:form">
                <div className="mns:form-row">
                    <label>Method</label>
                    <select value={method} onChange={(e) => setMethod(e.target.value as 'GET' | 'PUT')}>
                        <option value="PUT">Upload (PUT)</option>
                        <option value="GET">Download (GET)</option>
                    </select>
                </div>
                <div className="mns:form-row">
                    <label>Object Key</label>
                    <input type="text" value={objectKey} onChange={(e) => setObjectKey(e.target.value)} />
                </div>
                <button className="mns:btn mns:btn-primary" onClick={handlePresign} disabled={loading || !objectKey}>
                    {loading ? 'Generating...' : 'Generate Presigned URL'}
                </button>
            </div>

            {result !== null && (
                <div>
                    <h2>Presigned URL</h2>
                    {isExpired && <div className="mns:expiry-warning">This URL has expired. Generate a new one.</div>}
                    <div className="mns:presigned-url">{result.url}</div>
                    <p>
                        <strong>Method:</strong> {result.method}
                        <br />
                        <strong>Expires at:</strong> {result.expires_at}
                    </p>
                </div>
            )}
        </div>
    );
}
