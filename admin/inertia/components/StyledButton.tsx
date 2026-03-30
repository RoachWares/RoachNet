import { useMemo } from 'react'
import clsx from 'clsx'
import DynamicIcon, { DynamicIconName} from './DynamicIcon'
import { IconRefresh } from '@tabler/icons-react'

export interface StyledButtonProps extends React.HTMLAttributes<HTMLButtonElement> {
  children: React.ReactNode
  icon?: DynamicIconName
  disabled?: boolean
  variant?: 'primary' | 'secondary' | 'danger' | 'action' | 'success' | 'ghost' | 'outline'
  size?: 'sm' | 'md' | 'lg'
  loading?: boolean
  fullWidth?: boolean
}

const StyledButton: React.FC<StyledButtonProps> = ({
  children,
  icon,
  variant = 'primary',
  size = 'md',
  loading = false,
  fullWidth = false,
  className,
  ...props
}) => {
  const isDisabled = useMemo(() => {
    return props.disabled || loading
  }, [props.disabled, loading])

  const getIconSize = () => {
    switch (size) {
      case 'sm':
        return 'h-3.5 w-3.5 mr-1.5'
      case 'lg':
        return 'h-5 w-5 mr-2.5'
      default:
        return 'h-4 w-4 mr-2'
    }
  }

  const getSizeClasses = () => {
    switch (size) {
      case 'sm':
        return 'px-3 py-1.5 text-[0.72rem] uppercase tracking-[0.18em]'
      case 'lg':
        return 'px-5 py-3 text-sm uppercase tracking-[0.18em]'
      default:
        return 'px-4 py-2.5 text-[0.78rem] uppercase tracking-[0.18em]'
    }
  }

  const getVariantClasses = () => {
    const baseTransition = 'transition-all duration-200 ease-in-out'
    const baseHover = 'hover:shadow-[0_12px_28px_rgba(0,0,0,0.25)] active:scale-[0.985]'

    switch (variant) {
      case 'primary':
        return clsx(
          'bg-desert-green text-desert-green-darker border border-desert-green-light/40',
          'hover:bg-btn-green-hover hover:text-desert-green-darker',
          'active:bg-btn-green-active',
          'disabled:bg-desert-green-light disabled:text-desert-green-darker',
          baseTransition,
          baseHover
        )

      case 'secondary':
        return clsx(
          'bg-desert-tan text-white border border-desert-tan-light/30',
          'hover:bg-desert-tan-dark',
          'active:bg-desert-tan-dark',
          'disabled:bg-desert-tan-lighter disabled:text-desert-stone-light',
          baseTransition,
          baseHover
        )

      case 'danger':
        return clsx(
          'bg-desert-red text-white border border-desert-red-light/25',
          'hover:bg-desert-red-dark',
          'active:bg-desert-red-dark',
          'disabled:bg-desert-red-lighter disabled:text-desert-stone-light',
          baseTransition,
          baseHover
        )

      case 'action':
        return clsx(
          'bg-desert-orange text-white border border-desert-orange-light/30',
          'hover:bg-desert-orange-light',
          'active:bg-desert-orange-dark',
          'disabled:bg-desert-orange-lighter disabled:text-desert-stone-light',
          baseTransition,
          baseHover
        )

      case 'success':
        return clsx(
          'bg-desert-olive text-white border border-desert-olive-light/30',
          'hover:bg-desert-olive-dark',
          'active:bg-desert-olive-dark',
          'disabled:bg-desert-olive-lighter disabled:text-desert-stone-light',
          baseTransition,
          baseHover
        )

      case 'ghost':
        return clsx(
          'bg-transparent text-desert-green-light',
          'hover:bg-surface-secondary hover:text-desert-green-light',
          'active:bg-desert-green-lighter',
          'disabled:text-desert-stone-light',
          baseTransition
        )

      case 'outline':
        return clsx(
          'bg-transparent border border-border-default text-desert-green-light',
          'hover:bg-desert-green hover:text-desert-green-darker hover:border-btn-green-hover',
          'active:bg-btn-green-hover active:border-btn-green-active',
          'disabled:border-desert-green-lighter disabled:text-desert-stone-light',
          baseTransition,
          baseHover
        )

      default:
        return ''
    }
  }

  const getLoadingSpinner = () => {
    const spinnerSize = size === 'sm' ? 'h-3.5 w-3.5' : size === 'lg' ? 'h-5 w-5' : 'h-4 w-4'
    return (
      <IconRefresh
        className={clsx(spinnerSize, 'animate-spin')}
      />
    )
  }

  const onClickHandler = (e: React.MouseEvent<HTMLButtonElement>) => {
    if (isDisabled) {
      e.preventDefault()
      return
    }
    props.onClick?.(e)
  }

  return (
    <button
      type="button"
      className={clsx(
        'roachnet-button',
        `roachnet-button--${variant}`,
        fullWidth ? 'flex w-full' : 'inline-flex',
        getSizeClasses(),
        getVariantClasses(),
        isDisabled ? 'pointer-events-none opacity-60' : 'cursor-pointer',
        'items-center justify-center rounded-[1rem] font-semibold focus:outline-none focus:ring-2 focus:ring-desert-green-light focus:ring-offset-2 focus:ring-offset-desert-sand disabled:cursor-not-allowed disabled:shadow-none',
        className
      )}
      {...props}
      disabled={isDisabled}
      onClick={onClickHandler}
    >
      <span className="relative z-10 inline-flex items-center justify-center">
        {loading ? (
          getLoadingSpinner()
        ) : (
          <>
            {icon && <DynamicIcon icon={icon} className={getIconSize()} />}
            {children}
          </>
        )}
      </span>
    </button>
  )
}

export default StyledButton
