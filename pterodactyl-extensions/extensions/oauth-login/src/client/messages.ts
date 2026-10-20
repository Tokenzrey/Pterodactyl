import type { ProviderId } from './config';

export const PROVIDER_LABELS: Record<ProviderId, string> = {
    discord: 'Discord',
    github: 'GitHub',
    google: 'Google',
};

export interface Notice {
    title: string;
    body: string;
}

/**
 * One entry per error code the backend can send (`?oauth_error=`). The words come from this table only, never
 * from the URL, and a code that is not here shows nothing.
 */
export const LOGIN_ERRORS = {
    denied: { title: 'Sign-in cancelled', body: 'You left the provider before finishing. Choose a provider to try again.' },
    invalid_state: { title: 'That sign-in attempt expired', body: 'Start again from this page. If it keeps happening, check that cookies are on and use one browser tab.' },
    provider_error: { title: 'The provider could not finish the sign-in', body: 'Try again in a minute. If it keeps failing, tell an administrator.' },
    email_unverified: { title: 'No verified email on that account', body: 'Verify your email address with the provider, then try again.' },
    no_account: { title: 'No account matches that email', body: 'Ask an administrator to create an account for this email address. If you already have one under a different email, sign in with your username and password.' },
    admin_blocked: { title: 'Administrators sign in with a password', body: 'This sign-in method is turned off for administrator accounts.' },
    two_factor_required: { title: 'Use your password and authentication code', body: 'Accounts with two-factor authentication cannot use this sign-in method.' },
    identity_conflict: { title: 'That account is connected to another user', body: 'This provider account is linked to a different Panel account. Sign in to that account and disconnect it under Connected accounts, or ask an administrator.' },
    registration_failed: { title: 'Your account could not be created', body: 'Tell an administrator, and mention the time of this attempt.' },
    provider_unavailable: { title: 'This sign-in method is off', body: 'An administrator turned it off or has not finished setting it up.' },
} as const satisfies Record<string, Notice>;

export type ErrorCode = keyof typeof LOGIN_ERRORS;

/** The same codes on the "Connected accounts" page, where the person is already signed in. */
export const ACCOUNT_ERRORS: Record<ErrorCode, Notice> = {
    ...LOGIN_ERRORS,
    denied: { title: 'Connection cancelled', body: 'Nothing was changed.' },
    invalid_state: { title: 'That connection attempt expired', body: 'Choose Connect to start again. If it keeps happening, check that cookies are on.' },
    identity_conflict: { title: 'That account cannot be connected', body: 'It belongs to another Panel account, or you already connected a different account of this provider. Disconnect that one first.' },
};

export function isErrorCode(value: string | null): value is ErrorCode {
    return value !== null && Object.hasOwn(LOGIN_ERRORS, value);
}

/** A plain link, followed by a full page load: the browser has to leave the panel for the provider. */
export function redirectPath(id: ProviderId): string {
    return `/extensions/oauth-login/redirect/${id}`;
}

export function linkPath(id: ProviderId): string {
    return `/extensions/oauth-login/link/${id}`;
}
