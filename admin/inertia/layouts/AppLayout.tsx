import { lazy, Suspense, useState } from 'react'
import Footer from '~/components/Footer'
import ChatButton from '~/components/chat/ChatButton'
import useAIRuntimeStatus from '~/hooks/useAIRuntimeStatus'
import { Link } from '@inertiajs/react'
import { IconArrowLeft, IconHexagonLetterR, IconMap2, IconShieldBolt } from '@tabler/icons-react'
import RoachNetBrand from '~/components/RoachNetBrand'

const LazyChatModal = lazy(() => import('~/components/chat/ChatModal'))

export default function AppLayout({ children }: { children: React.ReactNode }) {
  const [isChatOpen, setIsChatOpen] = useState(false)
  const aiAssistantRuntime = useAIRuntimeStatus('ollama')

  return (
    <div className="roachnet-shell min-h-screen flex flex-col px-3 py-3 md:px-5 md:py-5">
      <div className="roachnet-panel relative overflow-hidden rounded-[2rem] border border-border-subtle">
        <div className="absolute inset-x-0 top-0 h-px roachnet-divider" />
        <div className="relative px-5 py-6 md:px-8 md:py-8">
          <div className="flex flex-col gap-6 xl:flex-row xl:items-end xl:justify-between">
            <button
              type="button"
              className="cursor-pointer text-left"
              onClick={() => (window.location.href = '/home')}
            >
              <RoachNetBrand
                size="xl"
                subtitle="Offline command grid for maps, archives, local AI, and field ops"
              />
            </button>

            <div className="flex flex-wrap gap-3">
              <div className="roachnet-card rounded-full px-4 py-2 text-xs uppercase tracking-[0.26em] text-desert-green-light">
                <IconShieldBolt className="mr-2 inline size-4" />
                Offline First
              </div>
              <div className="roachnet-card rounded-full px-4 py-2 text-xs uppercase tracking-[0.26em] text-desert-orange-light">
                <IconMap2 className="mr-2 inline size-4" />
                Maps, Docs, AI
              </div>
              <div className="roachnet-card rounded-full px-4 py-2 text-xs uppercase tracking-[0.26em] text-desert-tan-light">
                <IconHexagonLetterR className="mr-2 inline size-4" />
                Local Control
              </div>
            </div>
          </div>

          {window.location.pathname !== '/home' && (
            <div className="mt-6">
              <Link
                href="/home"
                className="roachnet-button roachnet-button--outline inline-flex items-center rounded-full border border-border-default bg-surface-secondary/80 px-4 py-2 text-sm font-semibold text-text-secondary transition-colors hover:text-desert-green-light"
              >
                <IconArrowLeft className="mr-2 size-4" />
                Back to Home
              </Link>
            </div>
          )}
        </div>

        <div className="relative flex-1">{children}</div>
      </div>
      <Footer />

      {aiAssistantRuntime.available && (
        <>
          <ChatButton onClick={() => setIsChatOpen(true)} />
          {isChatOpen && (
            <Suspense
              fallback={
                <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/35 backdrop-blur-sm">
                  <div className="roachnet-card rounded-[1.5rem] border border-border-default px-6 py-5 text-sm uppercase tracking-[0.2em] text-text-secondary">
                    Loading Chat
                  </div>
                </div>
              }
            >
              <LazyChatModal open={isChatOpen} onClose={() => setIsChatOpen(false)} />
            </Suspense>
          )}
        </>
      )}
    </div>
  )
}
