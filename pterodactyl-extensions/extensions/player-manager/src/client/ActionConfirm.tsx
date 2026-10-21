import { Button, Input, Label } from '@pterodactyl/sdk';
import { useId, useState } from 'react';
import { ACTIONS } from './actions';
import type { PlayerAction } from './api';

/** Asks before an action runs: says what will happen, takes a reason for kick and ban, and names the action on the button. */
export function ActionConfirm({ name, action, busy, onConfirm, onCancel }: {
    name: string;
    action: PlayerAction;
    busy: boolean;
    onConfirm: (reason: string) => void;
    onCancel: () => void;
}) {
    const copy = ACTIONS[action];
    const [reason, setReason] = useState('');
    const id = useId();

    return (
        <div role="group" aria-label={copy.question(name)} className="plm:mt-3 plm:rounded-md plm:border plm:border-border plm:bg-muted plm:p-3 plm:text-sm">
            <p className="plm:font-medium">{copy.question(name)}</p>
            <p className="plm:mt-1 plm:text-foreground/80">{copy.effect(name)}</p>

            {copy.reason ? (
                <div className="plm:mt-3">
                    <Label htmlFor={id}>Reason (optional)</Label>
                    <Input id={id} value={reason} onChange={(event) => setReason(event.target.value)} maxLength={256} autoComplete="off" />
                </div>
            ) : null}

            <div className="plm:mt-3 plm:flex plm:gap-2">
                <Button color="red" size="small" onClick={() => onConfirm(reason)} isLoading={busy}>
                    {copy.confirm(name)}
                </Button>
                <Button color="grey" isSecondary size="small" onClick={onCancel} disabled={busy}>
                    Cancel
                </Button>
            </div>
        </div>
    );
}
