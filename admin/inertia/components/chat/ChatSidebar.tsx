import classNames from '~/lib/classNames'
import StyledButton from '../StyledButton'
import { router, usePage } from '@inertiajs/react'
import { ChatSession } from '../../../types/chat'
import { IconMessage, IconSearch } from '@tabler/icons-react'
import { useMemo, useState } from 'react'
import KnowledgeBaseModal from './KnowledgeBaseModal'
import RoachNetBrand from '../RoachNetBrand'

interface ChatSidebarProps {
  sessions: ChatSession[]
  activeSessionId: string | null
  onSessionSelect: (id: string) => void
  onNewChat: () => void
  onClearHistory: () => void
  isInModal?: boolean
}

export default function ChatSidebar({
  sessions,
  activeSessionId,
  onSessionSelect,
  onNewChat,
  onClearHistory,
  isInModal = false,
}: ChatSidebarProps) {
  const { aiAssistantName } = usePage<{ aiAssistantName: string }>().props
  const [isKnowledgeBaseModalOpen, setIsKnowledgeBaseModalOpen] = useState(
    () => new URLSearchParams(window.location.search).get('knowledge_base') === 'true'
  )
  const [searchQuery, setSearchQuery] = useState('')

  const filteredSessions = useMemo(() => {
    const normalizedQuery = searchQuery.trim().toLowerCase()
    if (!normalizedQuery) {
      return sessions
    }

    return sessions.filter((session) =>
      [session.title, session.lastMessage || ''].some((value) =>
        value.toLowerCase().includes(normalizedQuery)
      )
    )
  }, [searchQuery, sessions])

  const groupedSessions = useMemo(() => {
    const now = new Date()
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    const startOfYesterday = new Date(startOfToday)
    startOfYesterday.setDate(startOfYesterday.getDate() - 1)
    const startOfWeek = new Date(startOfToday)
    startOfWeek.setDate(startOfWeek.getDate() - 6)

    const buckets: Array<{ label: string; sessions: ChatSession[] }> = [
      { label: 'Today', sessions: [] },
      { label: 'Yesterday', sessions: [] },
      { label: 'This Week', sessions: [] },
      { label: 'Older', sessions: [] },
    ]

    for (const session of filteredSessions) {
      if (session.timestamp >= startOfToday) {
        buckets[0].sessions.push(session)
      } else if (session.timestamp >= startOfYesterday) {
        buckets[1].sessions.push(session)
      } else if (session.timestamp >= startOfWeek) {
        buckets[2].sessions.push(session)
      } else {
        buckets[3].sessions.push(session)
      }
    }

    return buckets.filter((bucket) => bucket.sessions.length > 0)
  }, [filteredSessions])

  function handleCloseKnowledgeBase() {
    setIsKnowledgeBaseModalOpen(false)
    const params = new URLSearchParams(window.location.search)
    if (params.has('knowledge_base')) {
      params.delete('knowledge_base')
      const newUrl = [window.location.pathname, params.toString()].filter(Boolean).join('?')
      window.history.replaceState(window.history.state, '', newUrl)
    }
  }

  return (
    <div className="w-64 bg-surface-secondary border-r border-border-subtle flex flex-col h-full">
      <div className="p-4 border-b border-border-subtle h-[75px] flex items-center justify-center">
        <StyledButton onClick={onNewChat} icon="IconPlus" variant="primary" fullWidth>
          New Chat
        </StyledButton>
      </div>

      <div className="border-b border-border-subtle px-4 py-3">
        <label className="relative block">
          <IconSearch className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
          <input
            value={searchQuery}
            onChange={(event) => setSearchQuery(event.target.value)}
            placeholder="Search chats"
            className="w-full rounded-xl border border-border-default bg-surface-primary px-10 py-2.5 text-sm text-text-primary outline-none transition focus:border-desert-green/40 focus:ring-2 focus:ring-desert-green/20"
          />
        </label>
      </div>

      <div className="flex-1 overflow-y-auto">
        {sessions.length === 0 ? (
          <div className="p-4 text-center text-text-muted text-sm">No previous chats</div>
        ) : groupedSessions.length === 0 ? (
          <div className="p-4 text-center text-text-muted text-sm">No chats match that search</div>
        ) : (
          <div className="space-y-4 p-2">
            {groupedSessions.map((group) => (
              <div key={group.label}>
                <div className="px-3 pb-2 pt-1 text-[11px] font-semibold uppercase tracking-[0.2em] text-text-muted">
                  {group.label}
                </div>
                <div className="space-y-1">
                  {group.sessions.map((session) => (
                    <button
                      key={session.id}
                      onClick={() => onSessionSelect(session.id)}
                      className={classNames(
                        'w-full rounded-xl px-3 py-2 text-left transition-colors group',
                        activeSessionId === session.id
                          ? 'bg-desert-green text-white'
                          : 'text-text-primary hover:bg-surface-primary'
                      )}
                    >
                      <div className="flex items-start gap-2">
                        <IconMessage
                          className={classNames(
                            'mt-0.5 h-5 w-5 shrink-0',
                            activeSessionId === session.id ? 'text-white' : 'text-text-muted'
                          )}
                        />
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-sm font-medium">{session.title}</div>
                          {session.lastMessage && (
                            <div
                              className={classNames(
                                'mt-0.5 truncate text-xs',
                                activeSessionId === session.id ? 'text-white/80' : 'text-text-muted'
                              )}
                            >
                              {session.lastMessage}
                            </div>
                          )}
                        </div>
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="p-4 flex flex-col items-center justify-center gap-y-2">
        <RoachNetBrand
          size="md"
          subtitle={aiAssistantName}
          align="center"
          className="mb-4 flex-col"
        />
        <StyledButton
          onClick={() => {
            if (isInModal) {
              window.open('/chat', '_blank')
            } else {
              router.visit('/home')
            }
          }}
          icon={isInModal ? 'IconExternalLink' : 'IconHome'}
          variant="outline"
          size="sm"
          fullWidth
        >
          {isInModal ? 'Open in New Tab' : 'Back to Home'}
        </StyledButton>
        <StyledButton
          onClick={() => {
            router.visit('/settings/models')
          }}
          icon="IconDatabase"
          variant="primary"
          size="sm"
          fullWidth
        >
          Models & Settings
        </StyledButton>
        <StyledButton
          onClick={() => {
            setIsKnowledgeBaseModalOpen(true)
          }}
          icon="IconBrain"
          variant="primary"
          size="sm"
          fullWidth
        >
          Knowledge Base
        </StyledButton>
        {sessions.length > 0 && (
          <StyledButton
            onClick={onClearHistory}
            icon="IconTrash"
            variant="danger"
            size="sm"
            fullWidth
          >
            Clear History
          </StyledButton>
        )}
      </div>
      {isKnowledgeBaseModalOpen && (
        <KnowledgeBaseModal aiAssistantName={aiAssistantName} onClose={handleCloseKnowledgeBase} />
      )}
    </div>
  )
}
