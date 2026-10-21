import type { PlayerAction } from './api';

/** The words for each action: what the button says, what is asked, what will happen, and what is said afterwards. */
export interface ActionCopy {
    button: (name: string) => string;
    question: (name: string) => string;
    confirm: (name: string) => string;
    effect: (name: string) => string;
    done: (name: string) => string;
    /** Only kick and ban take a reason. */
    reason: boolean;
}

export const ACTIONS: Record<PlayerAction, ActionCopy> = {
    kick: {
        button: (name) => `Kick ${name}`,
        question: (name) => `Kick ${name}?`,
        confirm: (name) => `Yes, kick ${name}`,
        effect: (name) => `${name} is disconnected now and can join again.`,
        // "Sent", not "done": the server answers success even when the player had already left.
        done: (name) => `Kick command sent for ${name}.`,
        reason: true,
    },
    ban: {
        button: (name) => `Ban ${name}`,
        question: (name) => `Ban ${name}?`,
        confirm: (name) => `Yes, ban ${name}`,
        effect: (name) => `${name} is disconnected and cannot join until you run "pardon ${name}" in the console.`,
        done: (name) => `Ban command sent for ${name}.`,
        reason: true,
    },
    op: {
        button: (name) => `Make ${name} an OP`,
        question: (name) => `Make ${name} an OP?`,
        confirm: (name) => `Yes, make ${name} an OP`,
        effect: (name) => `${name} will be able to run every command on the server.`,
        done: (name) => `OP command sent for ${name}.`,
        reason: false,
    },
    deop: {
        button: (name) => `Remove OP from ${name}`,
        question: (name) => `Remove OP from ${name}?`,
        confirm: (name) => `Yes, remove OP from ${name}`,
        effect: (name) => `${name} will lose operator commands.`,
        done: (name) => `De-OP command sent for ${name}.`,
        reason: false,
    },
};

/** The same rule the backend applies before a name is put in a command (T-PM1): 3 to 16 letters, digits or underscores. */
export const VALID_NAME = /^[A-Za-z0-9_]{3,16}$/;
