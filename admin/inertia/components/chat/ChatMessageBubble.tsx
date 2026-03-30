import { IconCopy, IconCheck } from '@tabler/icons-react'
import classNames from '~/lib/classNames'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { useState } from 'react'
import { ChatMessage } from '../../../types/chat'

export interface ChatMessageBubbleProps {
  message: ChatMessage
}

export default function ChatMessageBubble({ message }: ChatMessageBubbleProps) {
  const [copiedSnippet, setCopiedSnippet] = useState<string | null>(null)

  const handleCopy = async (value: string) => {
    try {
      await navigator.clipboard.writeText(value)
      setCopiedSnippet(value)
      window.setTimeout(() => {
        setCopiedSnippet((current) => (current === value ? null : current))
      }, 1500)
    } catch {
      setCopiedSnippet(null)
    }
  }

  return (
    <div
      className={classNames(
        'group max-w-[70%] rounded-2xl px-4 py-3 shadow-sm',
        message.role === 'user' ? 'bg-desert-green text-white' : 'bg-surface-secondary text-text-primary'
      )}
    >
      {message.isThinking && message.thinking && (
        <div className="mb-3 rounded-2xl border border-border-subtle bg-surface-secondary px-3 py-2 text-xs">
          <div className="mb-1 flex items-center gap-1.5 font-medium text-desert-orange-light">
            <span>Reasoning</span>
            <span className="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-desert-orange-light" />
          </div>
          <div className="prose prose-xs max-w-none max-h-32 overflow-y-auto text-text-secondary">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>{message.thinking}</ReactMarkdown>
          </div>
        </div>
      )}
      {!message.isThinking && message.thinking && (
        <details className="mb-3 rounded border border-border-subtle bg-surface-secondary text-xs">
          <summary className="cursor-pointer px-3 py-2 font-medium text-text-muted hover:text-text-primary select-none">
            {message.thinkingDuration !== undefined
              ? `Thought for ${message.thinkingDuration}s`
              : 'Reasoning'}
          </summary>
          <div className="px-3 pb-3 prose prose-xs max-w-none text-text-secondary max-h-48 overflow-y-auto border-t border-border-subtle pt-2">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>{message.thinking}</ReactMarkdown>
          </div>
        </details>
      )}
      <div
        className={classNames(
          'break-words',
          message.role === 'assistant' ? 'prose prose-sm max-w-none' : 'whitespace-pre-wrap'
        )}
      >
        {message.role === 'assistant' ? (
          <ReactMarkdown
            remarkPlugins={[remarkGfm]}
            components={{
              code: ({ node, className, children, ...props }: any) => {
                const isInline = !className?.includes('language-')
                const codeContent = String(children).replace(/\n$/, '')
                if (isInline) {
                  return (
                    <code
                      className="bg-gray-800 text-gray-100 px-2 py-0.5 rounded font-mono text-sm"
                      {...props}
                    >
                      {children}
                    </code>
                  )
                }
                return (
                  <div className="relative my-2">
                    <button
                      type="button"
                      onClick={() => handleCopy(codeContent)}
                      className="absolute right-2 top-2 inline-flex items-center gap-1 rounded-full border border-white/10 bg-black/30 px-2 py-1 text-[11px] font-medium text-gray-100 transition hover:bg-black/50"
                    >
                      {copiedSnippet === codeContent ? (
                        <>
                          <IconCheck className="size-3.5" />
                          Copied
                        </>
                      ) : (
                        <>
                          <IconCopy className="size-3.5" />
                          Copy
                        </>
                      )}
                    </button>
                    <code
                      className="block overflow-x-auto rounded-xl bg-gray-950 p-3 pr-16 font-mono text-sm text-gray-100"
                      {...props}
                    >
                      {children}
                    </code>
                  </div>
                )
              },
              p: ({ children }) => <p className="mb-2 last:mb-0">{children}</p>,
              ul: ({ children }) => <ul className="list-disc pl-5 mb-2">{children}</ul>,
              ol: ({ children }) => <ol className="list-decimal pl-5 mb-2">{children}</ol>,
              li: ({ children }) => <li className="mb-1">{children}</li>,
              h1: ({ children }) => <h1 className="text-xl font-bold mb-2">{children}</h1>,
              h2: ({ children }) => <h2 className="text-lg font-bold mb-2">{children}</h2>,
              h3: ({ children }) => <h3 className="text-base font-bold mb-2">{children}</h3>,
              blockquote: ({ children }) => (
                <blockquote className="border-l-4 border-border-default pl-4 italic my-2">
                  {children}
                </blockquote>
              ),
              a: ({ children, href }) => (
                <a
                  href={href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-desert-green underline hover:text-desert-green/80"
                >
                  {children}
                </a>
              ),
            }}
          >
            {message.content}
          </ReactMarkdown>
        ) : (
          message.content
        )}
        {message.isStreaming && (
          <span className="inline-block w-2 h-4 ml-1 bg-current animate-pulse" />
        )}
      </div>
      <div
        className={classNames(
          'mt-2 text-xs opacity-0 transition-opacity group-hover:opacity-100',
          message.role === 'user' ? 'text-white/80' : 'text-text-muted'
        )}
      >
        {message.timestamp.toLocaleTimeString([], {
          hour: '2-digit',
          minute: '2-digit',
        })}
      </div>
    </div>
  )
}
