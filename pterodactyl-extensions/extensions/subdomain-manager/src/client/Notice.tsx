import { CircleAlert, CircleCheck, Info, TriangleAlert, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export type NoticeTone = 'success' | 'info' | 'warning' | 'danger';

const TONE: Record<NoticeTone, { icon: LucideIcon; frame: string; accent: string }> = {
    success: { icon: CircleCheck, frame: 'sdm:border-success/50 sdm:bg-success/10', accent: 'sdm:text-success' },
    info: { icon: Info, frame: 'sdm:border-primary/50 sdm:bg-primary/10', accent: 'sdm:text-primary' },
    warning: { icon: TriangleAlert, frame: 'sdm:border-warning/50 sdm:bg-warning/10', accent: 'sdm:text-warning' },
    danger: { icon: CircleAlert, frame: 'sdm:border-destructive/60 sdm:bg-destructive/10', accent: 'sdm:text-destructive' },
};

/**
 * A message that stands on its own: a full one-pixel frame and a tint, never a coloured side stripe. A danger
 * notice is announced at once; the others are polite status updates unless the caller says otherwise.
 */
export function Notice({ tone, title, role, children }: { tone: NoticeTone; title: string; role?: 'alert' | 'status'; children?: ReactNode }) {
    const { icon: Icon, frame, accent } = TONE[tone];

    return (
        <div role={role ?? (tone === 'danger' ? 'alert' : 'status')} className={`sdm:flex sdm:gap-3 sdm:rounded-md sdm:border sdm:p-4 ${frame}`}>
            <Icon aria-hidden="true" focusable="false" className={`sdm:mt-0.5 sdm:size-5 sdm:shrink-0 ${accent}`} />
            <div className="sdm:min-w-0 sdm:flex-1">
                <p className="sdm:font-medium">{title}</p>
                {children ? <div className="sdm:mt-1 sdm:text-sm sdm:text-foreground/80">{children}</div> : null}
            </div>
        </div>
    );
}
