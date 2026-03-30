import { useState } from 'react'
import { usePage } from '@inertiajs/react'
import { UsePageProps } from '../../types/system'
import ThemeToggle from '~/components/ThemeToggle'
import { IconBug } from '@tabler/icons-react'
import DebugInfoModal from './DebugInfoModal'
import RoachNetBrand from './RoachNetBrand'

export default function Footer() {
  const { appVersion } = usePage().props as unknown as UsePageProps
  const [debugModalOpen, setDebugModalOpen] = useState(false)

  return (
    <footer className="px-2 pb-2 pt-4">
      <div className="roachnet-panel flex flex-col gap-4 rounded-[1.5rem] border border-border-subtle px-5 py-4 md:flex-row md:items-center md:justify-between">
        <RoachNetBrand
          size="sm"
          subtitle={`Offline command grid v${appVersion}`}
          className="max-w-full"
        />
        <div className="flex flex-wrap items-center gap-3">
          <span className="text-xs uppercase tracking-[0.24em] text-text-muted">Diagnostics</span>
          <span className="text-border-default">|</span>
          <ThemeToggle />
        </div>
        <button
          onClick={() => setDebugModalOpen(true)}
          className="roachnet-button roachnet-button--ghost inline-flex items-center gap-1 rounded-full px-3 py-1.5 text-sm/6 text-text-secondary hover:text-desert-green-light cursor-pointer"
        >
          <span className="relative z-10 inline-flex items-center gap-1">
            <IconBug className="size-3.5" />
            Debug Info
          </span>
        </button>
      </div>
      <DebugInfoModal open={debugModalOpen} onClose={() => setDebugModalOpen(false)} />
    </footer>
  )
}
