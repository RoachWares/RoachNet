import ChatSession from '#models/chat_session'
import ChatMessage from '#models/chat_message'
import logger from '@adonisjs/core/services/logger'
import { DateTime } from 'luxon'
import { inject } from '@adonisjs/core'
import { OllamaService } from './ollama_service.js'
import { DEFAULT_QUERY_REWRITE_MODEL, SYSTEM_PROMPTS } from '../../constants/ollama.js'
import { toTitleCase } from '../utils/misc.js'

@inject()
export class ChatService {
  constructor(private ollamaService: OllamaService) {}
  private static readonly FALLBACK_SUGGESTIONS = [
    'Show me what is installed and what still needs setup',
    'Help me choose the best local RoachClaw model for this machine',
    'What content packs should I download first for offline use',
  ]

  private async withTimeout<T>(work: Promise<T>, timeoutMs: number, message: string): Promise<T> {
    let timeoutHandle: NodeJS.Timeout | undefined

    try {
      return await Promise.race([
        work,
        new Promise<T>((_, reject) => {
          timeoutHandle = setTimeout(() => reject(new Error(message)), timeoutMs)
        }),
      ])
    } finally {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }
    }
  }

  async getAllSessions() {
    try {
      const sessions = await ChatSession.query().orderBy('updated_at', 'desc')
      return sessions.map((session) => ({
        id: session.id.toString(),
        title: session.title,
        model: session.model,
        timestamp: session.updated_at.toJSDate(),
        lastMessage: null, // Will be populated from messages if needed
      }))
    } catch (error) {
      logger.error(
        `[ChatService] Failed to get sessions: ${error instanceof Error ? error.message : error}`
      )
      return []
    }
  }

  async getChatSuggestions() {
    try {
      if (process.env.ROACHNET_NATIVE_ONLY === '1') {
        return ChatService.FALLBACK_SUGGESTIONS
      }

      const models = await this.ollamaService.getModels()
      if (!models || models.length === 0) {
        return ChatService.FALLBACK_SUGGESTIONS
      }

      const cloudModel = models.find((model) => model.name.endsWith(':cloud'))
      const localModels = models.filter((model) => !model.name.endsWith(':cloud'))
      const sizedLocalModels = localModels.filter(
        (model) => typeof model.size === 'number' && model.size > 0
      )
      const largestLocalModel =
        (sizedLocalModels.length > 0 ? sizedLocalModels : localModels).reduce?.((prev, current) =>
          (prev.size ?? -1) > (current.size ?? -1) ? prev : current
        ) ?? null
      const suggestionModel = cloudModel ?? largestLocalModel

      if (!suggestionModel) {
        return ChatService.FALLBACK_SUGGESTIONS
      }

      const response = await this.withTimeout(
        this.ollamaService.chat({
          model: suggestionModel.name,
          messages: [
            {
              role: 'user',
              content: SYSTEM_PROMPTS.chat_suggestions,
            }
          ],
          stream: false,
        }),
        cloudModel ? 20_000 : 12_000,
        `Suggestion generation timed out for ${suggestionModel.name}`
      )

        if (response && response.message && response.message.content) {
            const content = response.message.content.trim()

        const suggestions = content
          .split(/\r?\n/)
          .flatMap((line) => line.split(','))
          .map((s) => s.trim())
          .map((s) => s.replace(/^\d+\.\s*/, '').replace(/^[-*•]\s*/, ''))
          .map((s) => s.replace(/^["']|["']$/g, ''))
          .filter((s) => s.length > 0)

        const uniqueSuggestions = Array.from(new Set(suggestions)).slice(0, 3)
        if (uniqueSuggestions.length > 0) {
          return uniqueSuggestions.map((s) => toTitleCase(s))
        }

        return ChatService.FALLBACK_SUGGESTIONS
      } else {
        return ChatService.FALLBACK_SUGGESTIONS
      }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to get chat suggestions: ${
          error instanceof Error ? error.message : error
        }`
      )
      return ChatService.FALLBACK_SUGGESTIONS
    }
  }

  async getSession(sessionId: number) {
    try {
      const session = await ChatSession.query().where('id', sessionId).preload('messages').first()

      if (!session) {
        return null
      }

      return {
        id: session.id.toString(),
        title: session.title,
        model: session.model,
        timestamp: session.updated_at.toJSDate(),
        messages: session.messages.map((msg) => ({
          id: msg.id.toString(),
          role: msg.role,
          content: msg.content,
          timestamp: msg.created_at.toJSDate(),
        })),
      }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to get session ${sessionId}: ${
          error instanceof Error ? error.message : error
        }`
      )
      return null
    }
  }

  async createSession(title: string, model?: string) {
    try {
      const session = await ChatSession.create({
        title,
        model: model || null,
      })

      return {
        id: session.id.toString(),
        title: session.title,
        model: session.model,
        timestamp: session.created_at.toJSDate(),
      }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to create session: ${error instanceof Error ? error.message : error}`
      )
      throw new Error('Failed to create chat session')
    }
  }

  async updateSession(sessionId: number, data: { title?: string; model?: string }) {
    try {
      const session = await ChatSession.findOrFail(sessionId)

      if (data.title) {
        session.title = data.title
      }
      if (data.model !== undefined) {
        session.model = data.model
      }

      await session.save()

      return {
        id: session.id.toString(),
        title: session.title,
        model: session.model,
        timestamp: session.updated_at.toJSDate(),
      }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to update session ${sessionId}: ${
          error instanceof Error ? error.message : error
        }`
      )
      throw new Error('Failed to update chat session')
    }
  }

  async addMessage(sessionId: number, role: 'system' | 'user' | 'assistant', content: string) {
    try {
      const message = await ChatMessage.create({
        session_id: sessionId,
        role,
        content,
      })

      // Update session's updated_at timestamp
      const session = await ChatSession.findOrFail(sessionId)
      session.updated_at = DateTime.now()
      await session.save()

      return {
        id: message.id.toString(),
        role: message.role,
        content: message.content,
        timestamp: message.created_at.toJSDate(),
      }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to add message to session ${sessionId}: ${
          error instanceof Error ? error.message : error
        }`
      )
      throw new Error('Failed to add message')
    }
  }

  async deleteSession(sessionId: number) {
    try {
      const session = await ChatSession.findOrFail(sessionId)
      await session.delete()
      return { success: true }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to delete session ${sessionId}: ${
          error instanceof Error ? error.message : error
        }`
      )
      throw new Error('Failed to delete chat session')
    }
  }

  async getMessageCount(sessionId: number): Promise<number> {
    try {
      const count = await ChatMessage.query().where('session_id', sessionId).count('* as total')
      return Number(count[0].$extras.total)
    } catch (error) {
      logger.error(
        `[ChatService] Failed to get message count for session ${sessionId}: ${error instanceof Error ? error.message : error}`
      )
      return 0
    }
  }

  async generateTitle(sessionId: number, userMessage: string, assistantMessage: string) {
    try {
      const models = await this.ollamaService.getModels()
      const titleModelAvailable = models?.some((m) => m.name === DEFAULT_QUERY_REWRITE_MODEL)

      let title: string

      if (!titleModelAvailable) {
        title = userMessage.slice(0, 57) + (userMessage.length > 57 ? '...' : '')
      } else {
        const response = await this.ollamaService.chat({
          model: DEFAULT_QUERY_REWRITE_MODEL,
          messages: [
            { role: 'system', content: SYSTEM_PROMPTS.title_generation },
            { role: 'user', content: userMessage },
            { role: 'assistant', content: assistantMessage },
          ],
        })

        title = response?.message?.content?.trim()
        if (!title) {
          title = userMessage.slice(0, 57) + (userMessage.length > 57 ? '...' : '')
        }
      }

      await this.updateSession(sessionId, { title })
      logger.info(`[ChatService] Generated title for session ${sessionId}: "${title}"`)
      return title
    } catch (error) {
      logger.error(
        `[ChatService] Failed to generate title for session ${sessionId}: ${error instanceof Error ? error.message : error}`
      )
      // Fall back to truncated user message
      try {
        const fallbackTitle = userMessage.slice(0, 57) + (userMessage.length > 57 ? '...' : '')
        await this.updateSession(sessionId, { title: fallbackTitle })
        return fallbackTitle
      } catch {
        // Silently fail - session keeps "New Chat" title
      }

      return null
    }
  }

  async deleteAllSessions() {
    try {
      await ChatSession.query().delete()
      return { success: true, message: 'All chat sessions deleted' }
    } catch (error) {
      logger.error(
        `[ChatService] Failed to delete all sessions: ${
          error instanceof Error ? error.message : error
        }`
      )
      throw new Error('Failed to delete all chat sessions')
    }
  }
}
