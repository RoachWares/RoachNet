import { useState, useCallback, useEffect, useRef, useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import ChatSidebar from './ChatSidebar'
import ChatInterface from './ChatInterface'
import ChatModelPicker from './ChatModelPicker'
import StyledModal from '../StyledModal'
import api, { type ChatStreamEvent } from '~/lib/api'
import { useModals } from '~/context/ModalContext'
import { ChatMessage } from '../../../types/chat'
import classNames from '~/lib/classNames'
import { IconX } from '@tabler/icons-react'
import { DEFAULT_QUERY_REWRITE_MODEL } from '../../../constants/ollama'
import { useSystemSetting } from '~/hooks/useSystemSetting'
import { useNotifications } from '~/context/NotificationContext'

interface ChatProps {
  enabled: boolean
  isInModal?: boolean
  onClose?: () => void
  suggestionsEnabled?: boolean
  streamingEnabled?: boolean
}

export default function Chat({
  enabled,
  isInModal,
  onClose,
  suggestionsEnabled = false,
  streamingEnabled = true,
}: ChatProps) {
  const queryClient = useQueryClient()
  const { openModal, closeAllModals } = useModals()
  const { addNotification } = useNotifications()
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [selectedModel, setSelectedModel] = useState<string>('')
  const [isStreamingResponse, setIsStreamingResponse] = useState(false)
  const [streamStatusMessage, setStreamStatusMessage] = useState<string | null>(null)
  const [cachedSuggestions, setCachedSuggestions] = useState<string[]>(() => {
    if (typeof window === 'undefined') {
      return []
    }

    try {
      const saved = window.sessionStorage.getItem('roachnet-chat-suggestions')
      return saved ? (JSON.parse(saved) as string[]) : []
    } catch {
      return []
    }
  })
  const streamAbortRef = useRef<AbortController | null>(null)

  // Fetch all sessions
  const { data: sessions = [] } = useQuery({
    queryKey: ['chatSessions'],
    queryFn: () => api.getChatSessions(),
    enabled,
    select: (data) =>
      data?.map((s) => ({
        id: s.id,
        title: s.title,
        model: s.model || undefined,
        timestamp: new Date(s.timestamp),
        lastMessage: s.lastMessage || undefined,
      })) || [],
  })

  const activeSession = sessions.find((s) => s.id === activeSessionId)

  const { data: lastModelSetting } = useSystemSetting({ key: 'chat.lastModel', enabled })

  const { data: installedModels = [], isLoading: isLoadingModels } = useQuery({
    queryKey: ['installedModels'],
    queryFn: () => api.getInstalledModels(),
    enabled,
    select: (data) => data || [],
  })

  const { data: chatSuggestions, isLoading: chatSuggestionsLoading } = useQuery<string[]>({
    queryKey: ['chatSuggestions'],
    queryFn: async ({ signal }) => {
      const res = await api.getChatSuggestions(signal)
      return res ?? []
    },
    enabled: suggestionsEnabled && !activeSessionId,
    refetchOnWindowFocus: false,
    refetchOnMount: true,
  })

  useEffect(() => {
    if (!chatSuggestions || chatSuggestions.length === 0 || typeof window === 'undefined') {
      return
    }

    setCachedSuggestions(chatSuggestions)
    window.sessionStorage.setItem('roachnet-chat-suggestions', JSON.stringify(chatSuggestions))
  }, [chatSuggestions])

  const rewriteModelAvailable = useMemo(() => {
    return installedModels.some(model => model.name === DEFAULT_QUERY_REWRITE_MODEL)
  }, [installedModels])

  const displayedSuggestions = useMemo(() => {
    return chatSuggestions && chatSuggestions.length > 0 ? chatSuggestions : cachedSuggestions
  }, [cachedSuggestions, chatSuggestions])

  useEffect(() => {
    return () => {
      streamAbortRef.current?.abort()
    }
  }, [])

  const deleteAllSessionsMutation = useMutation({
    mutationFn: () => api.deleteAllChatSessions(),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['chatSessions'] })
      setActiveSessionId(null)
      setMessages([])
      closeAllModals()
    },
  })

  const chatMutation = useMutation({
    mutationFn: (request: {
      model: string
      messages: Array<{ role: 'system' | 'user' | 'assistant'; content: string }>
      sessionId?: number
    }) => api.sendChatMessage({ ...request, stream: false }),
    onSuccess: async (data) => {
      if (!data || !activeSessionId) {
        throw new Error('No response from Ollama')
      }

      // Add assistant message
      const assistantMessage: ChatMessage = {
        id: `msg-${Date.now()}-assistant`,
        role: 'assistant',
        content: data.message?.content || 'Sorry, I could not generate a response.',
        timestamp: new Date(),
      }

      setMessages((prev) => [...prev, assistantMessage])

      queryClient.invalidateQueries({ queryKey: ['chatSessions'] })
    },
    onError: (error) => {
      console.error('Error sending message:', error)
      const errorMessage: ChatMessage = {
        id: `msg-${Date.now()}-error`,
        role: 'assistant',
        content: 'Sorry, there was an error processing your request. Please try again.',
        timestamp: new Date(),
      }
      setMessages((prev) => [...prev, errorMessage])
    },
  })

  // Set default model: prefer last used model, fall back to first installed if last model not available
  useEffect(() => {
    if (installedModels.length > 0 && !selectedModel) {
      const lastModel = lastModelSetting?.value as string | undefined
      if (lastModel && installedModels.some((m) => m.name === lastModel)) {
        setSelectedModel(lastModel)
      } else {
        setSelectedModel(installedModels[0].name)
      }
    }
  }, [installedModels, selectedModel, lastModelSetting])

  // Persist model selection
  useEffect(() => {
    if (selectedModel) {
      api.updateSetting('chat.lastModel', selectedModel)
    }
  }, [selectedModel])

  const handleNewChat = useCallback(() => {
    streamAbortRef.current?.abort()
    // Just clear the active session and messages - don't create a session yet
    setActiveSessionId(null)
    setMessages([])
    setStreamStatusMessage(null)
  }, [])

  const handleClearHistory = useCallback(() => {
    openModal(
      <StyledModal
        title="Clear All Chat History?"
        onConfirm={() => deleteAllSessionsMutation.mutate()}
        onCancel={closeAllModals}
        open={true}
        confirmText="Clear All"
        cancelText="Cancel"
        confirmVariant="danger"
      >
        <p className="text-text-primary">
          Are you sure you want to delete all chat sessions? This action cannot be undone and all
          conversations will be permanently deleted.
        </p>
      </StyledModal>,
      'confirm-clear-history-modal'
    )
  }, [openModal, closeAllModals, deleteAllSessionsMutation])

  const handleSessionSelect = useCallback(
    async (sessionId: string) => {
      streamAbortRef.current?.abort()
      // Cancel any ongoing suggestions fetch
      queryClient.cancelQueries({ queryKey: ['chatSuggestions'] })

      setActiveSessionId(sessionId)
      setStreamStatusMessage(null)
      // Load messages for this session
      const sessionData = await api.getChatSession(sessionId)
      if (sessionData?.messages) {
        setMessages(
          sessionData.messages.map((m) => ({
            id: m.id,
            role: m.role,
            content: m.content,
            timestamp: new Date(m.timestamp),
          }))
        )
      } else {
        setMessages([])
      }

      // Set the model to match the session's model if it exists and is available
      if (sessionData?.model) {
        setSelectedModel(sessionData.model)
      }
    },
    [installedModels, queryClient]
  )

  const handleStopStreaming = useCallback(() => {
    streamAbortRef.current?.abort()
  }, [])

  const patchSessionTitle = useCallback(
    (sessionId: string, title: string | null | undefined) => {
      if (!title) {
        return
      }

      queryClient.setQueryData<
        Array<{
          id: string
          title: string
          model: string | null
          timestamp: string
          lastMessage: string | null
        }>
      >(['chatSessions'], (current) => {
        if (!current) {
          return current
        }

        return current.map((session) =>
          session.id === sessionId
            ? {
                ...session,
                title,
                timestamp: new Date().toISOString(),
              }
            : session
        )
      })
    },
    [queryClient]
  )

  const handleSendMessage = useCallback(
    async (content: string) => {
      let sessionId = activeSessionId

      // Create a new session if none exists
      if (!sessionId) {
        const newSession = await api.createChatSession('New Chat', selectedModel)
        if (newSession) {
          sessionId = newSession.id
          setActiveSessionId(sessionId)
          queryClient.invalidateQueries({ queryKey: ['chatSessions'] })
        } else {
          return
        }
      }

      // Add user message to UI
      const userMessage: ChatMessage = {
        id: `msg-${Date.now()}`,
        role: 'user',
        content,
        timestamp: new Date(),
      }

      setMessages((prev) => [...prev, userMessage])

      const chatMessages = [
        ...messages.map((m) => ({ role: m.role, content: m.content })),
        { role: 'user' as const, content },
      ]

      if (streamingEnabled !== false) {
        // Streaming path
        const abortController = new AbortController()
        streamAbortRef.current = abortController

        setIsStreamingResponse(true)
        setStreamStatusMessage(null)

        const assistantMsgId = `msg-${Date.now()}-assistant`
        let isFirstChunk = true
        let isThinkingPhase = true
        let thinkingStartTime: number | null = null
        let thinkingDuration: number | null = null
        let doneEvent: Extract<ChatStreamEvent, { type: 'done' }> | null = null

        try {
          doneEvent = await api.streamChatMessage(
            { model: selectedModel || 'llama3.2', messages: chatMessages, stream: true, sessionId: sessionId ? Number(sessionId) : undefined },
            (event) => {
              if (event.type === 'status') {
                setStreamStatusMessage(event.message)
                return
              }

              if (event.type === 'done') {
                doneEvent = event
                setStreamStatusMessage(null)
                if (!event.persisted && event.error) {
                  addNotification({
                    type: 'info',
                    message: `Reply streamed, but RoachNet could not save it cleanly: ${event.error}`,
                  })
                }
                return
              }

              const { content: chunkContent, thinking: chunkThinking, done } = event
              setStreamStatusMessage(null)

              if (chunkThinking.length > 0 && thinkingStartTime === null) {
                thinkingStartTime = Date.now()
              }
              if (isFirstChunk) {
                isFirstChunk = false
                setMessages((prev) => [
                  ...prev,
                  {
                    id: assistantMsgId,
                    role: 'assistant',
                    content: chunkContent,
                    thinking: chunkThinking,
                    timestamp: new Date(),
                    isStreaming: true,
                    isThinking: chunkThinking.length > 0 && chunkContent.length === 0,
                    thinkingDuration: undefined,
                    statusText: null,
                  },
                ])
              } else {
                if (isThinkingPhase && chunkContent.length > 0) {
                  isThinkingPhase = false
                  if (thinkingStartTime !== null) {
                    thinkingDuration = Math.max(1, Math.round((Date.now() - thinkingStartTime) / 1000))
                  }
                }
                setMessages((prev) =>
                  prev.map((m) =>
                    m.id === assistantMsgId
                      ? {
                          ...m,
                          content: m.content + chunkContent,
                          thinking: (m.thinking ?? '') + chunkThinking,
                          isStreaming: !done,
                          isThinking: isThinkingPhase,
                          thinkingDuration: thinkingDuration ?? undefined,
                          statusText: null,
                        }
                      : m
                  )
                )
              }
            },
            abortController.signal
          )
        } catch (error: any) {
          if (error?.name === 'AbortError') {
            setMessages((prev) => {
              const hasAssistantMsg = prev.some((m) => m.id === assistantMsgId)
              if (hasAssistantMsg) {
                return prev.map((m) =>
                  m.id === assistantMsgId
                    ? {
                        ...m,
                        content: m.content
                          ? `${m.content}\n\nResponse stopped.`
                          : 'Response stopped.',
                        isStreaming: false,
                        isThinking: false,
                      }
                    : m
                )
              }

              return [
                ...prev,
                {
                  id: assistantMsgId,
                  role: 'assistant',
                  content: 'Response stopped.',
                  timestamp: new Date(),
                  isStreaming: false,
                },
              ]
            })
          } else {
            setMessages((prev) => {
              const hasAssistantMsg = prev.some((m) => m.id === assistantMsgId)
              if (hasAssistantMsg) {
                return prev.map((m) =>
                  m.id === assistantMsgId ? { ...m, isStreaming: false } : m
                )
              }
              return [
                ...prev,
                {
                  id: assistantMsgId,
                  role: 'assistant',
                  content: 'Sorry, there was an error processing your request. Please try again.',
                  timestamp: new Date(),
                },
              ]
            })
          }
        } finally {
          setIsStreamingResponse(false)
          setStreamStatusMessage(null)
          streamAbortRef.current = null
        }

        if (sessionId) {
          // Ensure the streaming cursor is removed
          setMessages((prev) =>
            prev.map((m) =>
              m.id === assistantMsgId ? { ...m, isStreaming: false } : m
            )
          )

          if (doneEvent?.title) {
            patchSessionTitle(sessionId, doneEvent.title)
          }

          queryClient.invalidateQueries({ queryKey: ['chatSessions'] })
        }
      } else {
        // Non-streaming (legacy) path
        chatMutation.mutate({
          model: selectedModel || 'llama3.2',
          messages: chatMessages,
          sessionId: sessionId ? Number(sessionId) : undefined,
        })
      }
    },
    [activeSessionId, addNotification, messages, patchSessionTitle, selectedModel, chatMutation, queryClient, streamingEnabled]
  )

  return (
    <div
      className={classNames(
        'flex border border-border-subtle overflow-hidden shadow-sm w-full',
        isInModal ? 'h-full rounded-lg' : 'h-screen'
      )}
    >
      <ChatSidebar
        sessions={sessions}
        activeSessionId={activeSessionId}
        onSessionSelect={handleSessionSelect}
        onNewChat={handleNewChat}
        onClearHistory={handleClearHistory}
        isInModal={isInModal}
      />
      <div className="flex-1 flex flex-col min-h-0">
        <div className="px-6 py-3 border-b border-border-subtle bg-surface-secondary flex items-center justify-between h-[75px] flex-shrink-0">
          <h2 className="text-lg font-semibold text-text-primary">
            {activeSession?.title || 'New Chat'}
          </h2>
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-2">
              <label htmlFor="model-select" className="text-sm text-text-secondary">
                Model:
              </label>
              {isLoadingModels ? (
                <div className="text-sm text-text-muted">Loading models...</div>
              ) : installedModels.length === 0 ? (
                <div className="text-sm text-red-600">No models installed</div>
              ) : (
                <ChatModelPicker
                  models={installedModels.map((model) => ({ name: model.name, size: model.size }))}
                  selectedModel={selectedModel}
                  onChange={setSelectedModel}
                />
              )}
            </div>
            {isInModal && (
              <button
                onClick={() => {
                  if (onClose) {
                    onClose()
                  }
                }}
                className="rounded-lg hover:bg-surface-secondary transition-colors"
              >
                <IconX className="h-6 w-6 text-text-muted" />
              </button>
            )}
          </div>
        </div>
        <ChatInterface
          messages={messages}
          onSendMessage={handleSendMessage}
          onStopStreaming={handleStopStreaming}
          isLoading={isStreamingResponse || chatMutation.isPending}
          showLoadingBubble={chatMutation.isPending || (isStreamingResponse && !messages.some((message) => message.isStreaming))}
          loadingLabel={streamStatusMessage || 'Thinking'}
          chatSuggestions={displayedSuggestions}
          chatSuggestionsEnabled={suggestionsEnabled}
          chatSuggestionsLoading={chatSuggestionsLoading && displayedSuggestions.length === 0}
          rewriteModelAvailable={rewriteModelAvailable}
        />
      </div>
    </div>
  )
}
