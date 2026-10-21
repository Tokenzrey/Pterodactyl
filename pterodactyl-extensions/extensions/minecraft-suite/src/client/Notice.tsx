import { CircleAlert, CircleCheck, Info, TriangleAlert, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export type NoticeTone = 'success' | 'info' | 'warning' | 'danger';

const TONE: Record<NoticeTone, { icon: LucideIcon; frame: string; accent: string }> = {
    success: { icon: CircleCheck, frame: 'mcs:border-success/50 mcs:bg-success/10', accent: 'mcs:text-success' },
    info: { icon: Info, frame: 'mcs:border-primary/50 mcs:bg-primary/10', accent: 'mcs:text-primary' },
    warning: { icon: TriangleAlert, frame: 'mcs:border-warning/50 mcs:bg-warning/10', accent: 'mcs:text-warning' },
    danger: { icon: CircleAlert, frame: 'mcs:border-destructive/60 mcs:bg-destructive/10', accent: 'mcs:text-destructive' },
};

/**
 * A message that stands on its own: a full one-pixel frame and a tint, never a coloured side stripe. A danger
 * notice is announced at once; the others are polite status updates unless the caller says otherwise.
 */
export function Notice({ tone, title, role, children }: { tone: NoticeTone; title: string; role?: 'alert' | 'status'; children?: ReactNode }) {
    const { icon: Icon, frame, accent } = TONE[tone];

    return (
        <div role={role ?? (tone === 'danger' ? 'alert' : 'status')} className={`mcs:flex mcs:gap-3 mcs:rounded-md mcs:border mcs:p-4 ${frame}`}>
            <Icon aria-hidden="true" focusable="false" className={`mcs:mt-0.5 mcs:size-5 mcs:shrink-0 ${accent}`} />
            <div className="mcs:min-w-0 mcs:flex-1">
                <p className="mcs:font-medium">{title}</p>
                {children ? <div className="mcs:mt-1 mcs:text-sm mcs:text-foreground/80">{children}</div> : null}
            </div>
        </div>
    );
}
