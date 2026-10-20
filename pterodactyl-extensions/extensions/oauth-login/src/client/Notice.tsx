import { CircleAlert, CircleCheck, Info, TriangleAlert, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export type NoticeTone = 'success' | 'info' | 'warning' | 'danger';

const TONE: Record<NoticeTone, { icon: LucideIcon; frame: string; accent: string }> = {
    success: { icon: CircleCheck, frame: 'olg:border-success/50 olg:bg-success/10', accent: 'olg:text-success' },
    info: { icon: Info, frame: 'olg:border-primary/50 olg:bg-primary/10', accent: 'olg:text-primary' },
    warning: { icon: TriangleAlert, frame: 'olg:border-warning/50 olg:bg-warning/10', accent: 'olg:text-warning' },
    danger: { icon: CircleAlert, frame: 'olg:border-destructive/60 olg:bg-destructive/10', accent: 'olg:text-destructive' },
};

/**
 * A message that stands on its own: a full one-pixel frame and a tint, never a coloured side stripe. A danger
 * notice is announced at once; the others are polite status updates unless the caller says otherwise.
 */
export function Notice({ tone, title, role, children }: { tone: NoticeTone; title: string; role?: 'alert' | 'status'; children?: ReactNode }) {
    const { icon: Icon, frame, accent } = TONE[tone];

    return (
        <div role={role ?? (tone === 'danger' ? 'alert' : 'status')} className={`olg:flex olg:gap-3 olg:rounded-md olg:border olg:p-4 ${frame}`}>
            <Icon aria-hidden="true" focusable="false" className={`olg:mt-0.5 olg:size-5 olg:shrink-0 ${accent}`} />
            <div className="olg:min-w-0 olg:flex-1">
                <p className="olg:font-medium">{title}</p>
                {children ? <div className="olg:mt-1 olg:text-sm olg:text-foreground/80">{children}</div> : null}
            </div>
        </div>
    );
}
