import { CircleAlert, CircleCheck, Info, TriangleAlert, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export type NoticeTone = 'success' | 'info' | 'warning' | 'danger';

const TONE: Record<NoticeTone, { icon: LucideIcon; frame: string; accent: string }> = {
    success: { icon: CircleCheck, frame: 'plm:border-success/50 plm:bg-success/10', accent: 'plm:text-success' },
    info: { icon: Info, frame: 'plm:border-primary/50 plm:bg-primary/10', accent: 'plm:text-primary' },
    warning: { icon: TriangleAlert, frame: 'plm:border-warning/50 plm:bg-warning/10', accent: 'plm:text-warning' },
    danger: { icon: CircleAlert, frame: 'plm:border-destructive/60 plm:bg-destructive/10', accent: 'plm:text-destructive' },
};

/**
 * A message that stands on its own: a full one-pixel frame and a tint, never a coloured side stripe. A danger
 * notice is announced at once; the others are polite status updates unless the caller says otherwise.
 */
export function Notice({ tone, title, role, children }: { tone: NoticeTone; title: string; role?: 'alert' | 'status'; children?: ReactNode }) {
    const { icon: Icon, frame, accent } = TONE[tone];

    return (
        <div role={role ?? (tone === 'danger' ? 'alert' : 'status')} className={`plm:flex plm:gap-3 plm:rounded-md plm:border plm:p-4 ${frame}`}>
            <Icon aria-hidden="true" focusable="false" className={`plm:mt-0.5 plm:size-5 plm:shrink-0 ${accent}`} />
            <div className="plm:min-w-0 plm:flex-1">
                <p className="plm:font-medium">{title}</p>
                {children ? <div className="plm:mt-1 plm:text-sm plm:text-foreground/80">{children}</div> : null}
            </div>
        </div>
    );
}
