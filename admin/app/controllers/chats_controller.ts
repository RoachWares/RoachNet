import { inject } from '@adonisjs/core'
import type { HttpContext } from '@adonisjs/core/http'
import { ChatService } from '#services/chat_service'
import { createSessionSchema, updateSessionSchema, addMessageSchema } from '#validators/chat'
import KVStore from '#models/kv_store'
import { AIRuntimeService } from '#services/ai_runtime_service'

@inject()
export default class ChatsController {
  private static readonly FALLBACK_SUGGESTIONS = [
    'Show me what is installed and what still needs setup',
    'Help me choose the best local RoachClaw model for this machine',
    'What content packs should I download first for offline use',
  ]

  constructor(private chatService: ChatService, private aiRuntimeService: AIRuntimeService) {}

  async inertia({ inertia, response }: HttpContext) {
    const aiAssistantAvailable = await this.aiRuntimeService.isProviderAvailable('ollama')
    if (!aiAssistantAvailable) {
      return response.status(404).json({ error: 'AI Assistant runtime not available' })
    }
    
    const chatSuggestionsEnabled = await KVStore.getValue('chat.suggestionsEnabled')
    return inertia.render('chat', {
      settings: {
        chatSuggestionsEnabled: chatSuggestionsEnabled ?? false,
      },
    })
  }

  async index({}: HttpContext) {
    return await this.chatService.getAllSessions()
  }

  async show({ params, response }: HttpContext) {
    const sessionId = parseInt(params.id)
    const session = await this.chatService.getSession(sessionId)

    if (!session) {
      return response.status(404).json({ error: 'Session not found' })
    }

    return session
  }

  async store({ request, response }: HttpContext) {
    try {
      const data = await request.validateUsing(createSessionSchema)
      const session = await this.chatService.createSession(data.title, data.model)
      return response.status(201).json(session)
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to create session',
      })
    }
  }

  async suggestions({ response }: HttpContext) {
    try {
      const suggestions = await this.chatService.getChatSuggestions()
      return response.status(200).json({
        suggestions:
          Array.isArray(suggestions) && suggestions.length > 0
            ? suggestions
            : ChatsController.FALLBACK_SUGGESTIONS,
      })
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to get suggestions',
      })
    }
  }

  async update({ params, request, response }: HttpContext) {
    try {
      const sessionId = parseInt(params.id)
      const data = await request.validateUsing(updateSessionSchema)
      const session = await this.chatService.updateSession(sessionId, data)
      return session
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to update session',
      })
    }
  }

  async destroy({ params, response }: HttpContext) {
    try {
      const sessionId = parseInt(params.id)
      await this.chatService.deleteSession(sessionId)
      return response.status(204)
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to delete session',
      })
    }
  }

  async addMessage({ params, request, response }: HttpContext) {
    try {
      const sessionId = parseInt(params.id)
      const data = await request.validateUsing(addMessageSchema)
      const message = await this.chatService.addMessage(sessionId, data.role, data.content)
      return response.status(201).json(message)
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to add message',
      })
    }
  }

  async destroyAll({ response }: HttpContext) {
    try {
      const result = await this.chatService.deleteAllSessions()
      return response.status(200).json(result)
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to delete all sessions',
      })
    }
  }
}
