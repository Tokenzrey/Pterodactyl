import { CircleAlert, CircleCheck, Info, TriangleAlert, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export type NoticeTone = 'success' | 'info' | 'warning' | 'danger';

const TONE: Record<NoticeTone, { icon: LucideIcon; frame: string; accent: string }> = {
    success: { icon: CircleCheck, frame: 'mki:border-success/50 mki:bg-success/10', accent: 'mki:text-success' },
    info: { icon: Info, frame: 'mki:border-primary/50 mki:bg-primary/10', accent: 'mki:text-primary' },
    warning: { icon: TriangleAlert, frame: 'mki:border-warning/50 mki:bg-warning/10', accent: 'mki:text-warning' },
    danger: { icon: CircleAlert, frame: 'mki:border-destructive/60 mki:bg-destructive/10', accent: 'mki:text-destructive' },
};

/**
 * A message that stands on its own: a full one-pixel frame and a tint, never a coloured side stripe. A danger
 * notice is announced at once; the others are polite status updates unless the caller says otherwise.
 */
export function Notice({ tone, title, role, children }: { tone: NoticeTone; title: string; role?: 'alert' | 'status'; children?: ReactNode }) {
    const { icon: Icon, frame, accent } = TONE[tone];

    return (
        <div role={role ?? (tone === 'danger' ? 'alert' : 'status')} className={`mki:flex mki:gap-3 mki:rounded-md mki:border mki:p-4 ${frame}`}>
            <Icon aria-hidden="true" focusable="false" className={`mki:mt-0.5 mki:size-5 mki:shrink-0 ${accent}`} />
            <div className="mki:min-w-0 mki:flex-1">
                <p className="mki:font-medium">{title}</p>
                {children ? <div className="mki:mt-1 mki:text-sm mki:text-foreground/80">{children}</div> : null}
            </div>
        </div>
    );
}
