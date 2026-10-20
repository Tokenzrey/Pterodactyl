import { useEffect, useState } from 'react';
import { PROVIDER_IDS, type ProviderId } from './config';
import { Notice } from './Notice';
import { ACCOUNT_ERRORS, isErrorCode, LOGIN_ERRORS, PROVIDER_LABELS, type ErrorCode } from './messages';

export type Result = { kind: 'error'; code: ErrorCode } | { kind: 'linked'; provider: ProviderId };

/** What the address says happened: `?oauth_error=<code>` or `?oauth_linked=<provider>`, if it is one this bundle knows. */
export function readResult(search: string): Result | null {
    const params = new URLSearchParams(search);
    const error = params.get('oauth_error');
    if (isErrorCode(error)) {
        return { kind: 'error', code: error };
    }
    const linked = PROVIDER_IDS.find((id) => id === params.get('oauth_linked'));

    return linked ? { kind: 'linked', provider: linked } : null;
}

/** Drops the result from the address, so reloading or sharing the page does not bring the message back. */
function clearResult(): void {
    const url = new URL(window.location.href);
    if (url.searchParams.has('oauth_error') || url.searchParams.has('oauth_linked')) {
        url.searchParams.delete('oauth_error');
        url.searchParams.delete('oauth_linked');
        window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash);
    }
}

/**
 * Says how a sign-in or a connect attempt ended. The text comes from this bundle's own table, never from the
 * address, and an unknown value shows nothing. It can be dismissed.
 */
export function ResultBanner({ context }: { context: 'login' | 'account' }) {
    const [result, setResult] = useState<Result | null>(() => readResult(window.location.search));

    useEffect(clearResult, []);

    if (!result) {
        return null;
    }

    const dismiss = (
        <button
            type="button"
            onClick={() => setResult(null)}
            className="olg:mt-2 olg:rounded-sm olg:text-xs olg:font-medium olg:underline olg:underline-offset-4 olg:focus-visible:outline-2 olg:focus-visible:outline-ring"
        >
            Dismiss
        </button>
    );

    if (result.kind === 'linked') {
        return (
            <div className="olg:mb-4">
                <Notice tone="success" role="alert" title={`${PROVIDER_LABELS[result.provider]} connected`}>
                    You can now sign in with {PROVIDER_LABELS[result.provider]}.
                    <div>{dismiss}</div>
                </Notice>
            </div>
        );
    }

    const notice = (context === 'account' ? ACCOUNT_ERRORS : LOGIN_ERRORS)[result.code];

    return (
        <div className="olg:mb-4">
            <Notice tone="danger" title={notice.title}>
                {notice.body}
                <div>{dismiss}</div>
            </Notice>
        </div>
    );
}
