import clsx from 'clsx'

type RoachNetBrandProps = {
  size?: 'sm' | 'md' | 'lg' | 'xl'
  subtitle?: string
  align?: 'left' | 'center'
  className?: string
}

const sizeClasses = {
  sm: {
    markShell: 'h-14 w-14',
    title: 'text-lg',
    subtitle: 'text-[0.65rem]',
    gap: 'gap-3',
  },
  md: {
    markShell: 'h-20 w-20',
    title: 'text-2xl',
    subtitle: 'text-[0.72rem]',
    gap: 'gap-4',
  },
  lg: {
    markShell: 'h-28 w-28 md:h-32 md:w-32',
    title: 'text-4xl md:text-5xl',
    subtitle: 'text-xs md:text-sm',
    gap: 'gap-5',
  },
  xl: {
    markShell: 'h-32 w-32 md:h-36 md:w-36',
    title: 'text-4xl md:text-5xl',
    subtitle: 'text-xs md:text-sm',
    gap: 'gap-5 md:gap-6',
  },
}

export default function RoachNetBrand({
  size = 'md',
  subtitle,
  align = 'left',
  className,
}: RoachNetBrandProps) {
  const config = sizeClasses[size]

  return (
    <div
      className={clsx(
        'flex items-center',
        config.gap,
        align === 'center' ? 'justify-center text-center' : 'justify-start text-left',
        className
      )}
    >
      <div className={clsx('roachnet-brand-mark-shell shrink-0', config.markShell)}>
        <img
          src="/roachnet-mark.png"
          alt="RoachNet mark"
          className="roachnet-brand-mark h-full w-full object-contain"
        />
      </div>
      <div className="min-w-0">
        <div className={clsx('roachnet-wordmark leading-none', config.title)}>RoachNet</div>
        {subtitle && (
          <div className={clsx('roachnet-kicker mt-2 text-text-secondary', config.subtitle)}>
            {subtitle}
          </div>
        )}
      </div>
    </div>
  )
}
