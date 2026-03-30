import { IconSun, IconMoon } from '@tabler/icons-react'
import { useThemeContext } from '~/providers/ThemeProvider'

interface ThemeToggleProps {
  compact?: boolean
}

export default function ThemeToggle({ compact = false }: ThemeToggleProps) {
  const { theme, toggleTheme } = useThemeContext()
  const isDark = theme === 'dark'

  return (
    <button
      onClick={toggleTheme}
      className="roachnet-button roachnet-button--outline inline-flex items-center gap-1.5 rounded-full border border-border-default bg-surface-secondary/80 px-3 py-1.5 text-sm text-text-secondary transition-colors hover:text-desert-green-light cursor-pointer"
      aria-label={isDark ? 'Switch to daylight mode' : 'Switch to stealth mode'}
      title={isDark ? 'Switch to daylight mode' : 'Switch to stealth mode'}
    >
      <span className="relative z-10 inline-flex items-center gap-1.5">
        {isDark ? <IconSun className="size-4" /> : <IconMoon className="size-4" />}
        {!compact && <span>{isDark ? 'Daylight' : 'Stealth'}</span>}
      </span>
    </button>
  )
}
