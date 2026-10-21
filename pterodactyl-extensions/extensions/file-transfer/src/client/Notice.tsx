import { CircleAlert, CircleCheck, Info, TriangleAlert, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export type NoticeTone = 'success' | 'info' | 'warning' | 'danger';

const TONE: Record<NoticeTone, { icon: LucideIcon; frame: string; accent: string }> = {
    success: { icon: CircleCheck, frame: 'ftr:border-success/50 ftr:bg-success/10', accent: 'ftr:text-success' },
    info: { icon: Info, frame: 'ftr:border-primary/50 ftr:bg-primary/10', accent: 'ftr:text-primary' },
    warning: { icon: TriangleAlert, frame: 'ftr:border-warning/50 ftr:bg-warning/10', accent: 'ftr:text-warning' },
    danger: { icon: CircleAlert, frame: 'ftr:border-destructive/60 ftr:bg-destructive/10', accent: 'ftr:text-destructive' },
};

/**
 * A message that stands on its own: a full one-pixel frame and a tint, never a coloured side stripe. A danger
 * notice is announced at once; the others are polite status updates unless the caller says otherwise.
 */
export function Notice({ tone, title, role, children }: { tone: NoticeTone; title: string; role?: 'alert' | 'status'; children?: ReactNode }) {
    const { icon: Icon, frame, accent } = TONE[tone];

    return (
        <div role={role ?? (tone === 'danger' ? 'alert' : 'status')} className={`ftr:flex ftr:gap-3 ftr:rounded-md ftr:border ftr:p-4 ${frame}`}>
            <Icon aria-hidden="true" focusable="false" className={`ftr:mt-0.5 ftr:size-5 ftr:shrink-0 ${accent}`} />
            <div className="ftr:min-w-0 ftr:flex-1">
                <p className="ftr:font-medium">{title}</p>
                {children ? <div className="ftr:mt-1 ftr:text-sm ftr:text-foreground/80">{children}</div> : null}
            </div>
        </div>
    );
}
