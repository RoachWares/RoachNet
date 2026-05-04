import { inject } from '@adonisjs/core'
import type { HttpContext } from '@adonisjs/core/http'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { ChatService } from '#services/chat_service'
import { MapService } from '#services/map_service'
import { OllamaService } from '#services/ollama_service'
import { ZimService } from '#services/zim_service'

type CompanionInstallInput = {
  installUrl?: string
  action?: string
  type?: string
  slug?: string
  category?: string
  tier?: string
  resource?: string
  resourceId?: string
  option?: string
  optionId?: string
  model?: string
  url?: string
  filetype?: string
  resourceType?: string
  metadata?: Record<string, unknown>
}

type CompanionInstallAction = {
  action: string
  slug?: string
  category?: string
  tier?: string
  resource?: string
  option?: string
  model?: string
  url?: string
  filetype?: string
  metadata?: Record<string, unknown>
}

type RoachBrainMemoryRecord = {
  id: string
  title: string
  summary: string
  source: string
  tags: string[]
  pinned: boolean
  lastAccessedAt: string
}

type RoachTailPeerRecord = {
  id: string
  name: string
  platform: string
  status: string
  endpoint?: string | null
  lastSeenAt?: string | null
  allowsExitNode?: boolean
  tags?: string[]
}

type InternalRoachTailPeerRecord = RoachTailPeerRecord & {
  tokenHash?: string | null
  pairedAt?: string | null
  appVersion?: string | null
}

type RoachTailStateRecord = {
  enabled: boolean
  networkName: string
  deviceName: string
  deviceId: string
  status: string
  transportMode: string
  secureOverlay: boolean
  relayHost?: string | null
  advertisedUrl?: string | null
  runtimeOrigin?: string | null
  runtimeTunnelUrl?: string | null
  joinCode?: string | null
  joinCodeIssuedAt?: string | null
  joinCodeExpiresAt?: string | null
  pairingPayload?: string | null
  pairingIssuedAt?: string | null
  lastUpdatedAt?: string | null
  notes: string[]
  peers: RoachTailPeerRecord[]
}

type InternalRoachTailStateRecord = Omit<RoachTailStateRecord, 'peers'> & {
  peers: InternalRoachTailPeerRecord[]
}

type RoachTailStateSanitizeOptions = {
  hideJoinCode?: boolean
}

const ROACHTAIL_JOIN_CODE_TTL_MS = 10 * 60 * 1000

type RoachSyncPeerRecord = {
  id: string
  name: string
  deviceId: string
  status: string
  lastSeenAt?: string | null
}

type RoachSyncStateRecord = {
  enabled: boolean
  provider: string
  networkName: string
  deviceName: string
  deviceId: string
  status: string
  folderId: string
  folderPath: string
  guiUrl?: string | null
  apiUrl?: string | null
  transportMode: string
  secureOverlay: boolean
  notes: string[]
  peers: RoachSyncPeerRecord[]
  lastUpdatedAt?: string | null
}

type RoachNetAccountStateRecord = {
  linked: boolean
  provider: string
  portalUrl: string
  accountId?: string | null
  email?: string | null
  displayName?: string | null
  status: string
  settingsSyncEnabled: boolean
  savedAppsSyncEnabled: boolean
  hostedChatEnabled: boolean
  aliasHost: string
  bridgeUrl?: string | null
  runtimeOrigin?: string | null
  linkedAt?: string | null
  lastSeenAt?: string | null
  lastUpdatedAt?: string | null
  notes: string[]
}

type RoachTailActionInput = {
  action?:
    | 'enable'
    | 'disable'
    | 'refresh-join-code'
    | 'clear-peers'
    | 'set-relay-host'
    | 'register-peer'
    | 'remove-peer'
  relayHost?: string | null
  peerId?: string | null
  peerName?: string | null
  platform?: string | null
  endpoint?: string | null
  allowsExitNode?: boolean
  tags?: string[]
}

type RoachSyncActionInput = {
  action?: 'enable' | 'disable' | 'refresh' | 'set-folder-path' | 'clear-peers'
  folderPath?: string | null
}

type RoachNetAccountActionInput = {
  action?: 'link' | 'unlink' | 'refresh'
  accountId?: string | null
  email?: string | null
  displayName?: string | null
  portalUrl?: string | null
  settingsSyncEnabled?: boolean
  savedAppsSyncEnabled?: boolean
  hostedChatEnabled?: boolean
}

type RoachTailPairInput = {
  joinCode?: string | null
  peerId?: string | null
  peerName?: string | null
  platform?: string | null
  endpoint?: string | null
  appVersion?: string | null
  allowsExitNode?: boolean
  tags?: string[]
}

type RelayIssue = {
  path: string
  error: string
}

type CompanionServiceActionInput = {
  serviceName?: string
  action?: 'start' | 'stop' | 'restart'
}

type CompanionChatInputMessage = {
  role?: 'system' | 'user' | 'assistant' | string
  content?: string
  images?: string[]
}

@inject()
export default class CompanionController {
  constructor(
    private chatService: ChatService,
    private ollamaService: OllamaService,
    private mapService: MapService,
    private zimService: ZimService
  ) {}

  async bootstrap({ request }: HttpContext) {
    const [runtime, vault, sessions, roachTail] = await Promise.all([
      this.runtimePayload(request),
      this.vaultPayload(request),
      this.chatService.getAllSessions(),
      this.roachTailPayload({
        hideJoinCode: this.isPeerRoachTailRequest(request),
      }),
    ])

    return {
      appName: 'RoachNet Companion',
      machineName: roachTail.deviceName || 'RoachNet desktop',
      appsCatalogUrl: 'https://apps.roachnet.org/app-store-catalog.json',
      runtime,
      vault,
      sessions: sessions.slice(0, 24),
    }
  }

  async runtime({ request }: HttpContext) {
    return this.runtimePayload(request)
  }

  async account() {
    return this.accountPayload()
  }

  async roachtail({ request }: HttpContext) {
    return this.roachTailPayload({
      hideJoinCode: this.isPeerRoachTailRequest(request),
    })
  }

  async roachsync() {
    return this.roachSyncPayload()
  }

  async pairRoachTail({ request, response }: HttpContext) {
    const payload = request.body() as RoachTailPairInput
    const joinCode = payload.joinCode?.trim().toUpperCase()

    if (!joinCode) {
      return response.status(400).json({
        error: 'A RoachTail join code is required to pair this device.',
      })
    }

    try {
      const pairing = await this.pairRoachTailPeer(joinCode, payload)
      return response.status(201).json(pairing)
    } catch (error) {
      return response.status(400).json({
        error: error instanceof Error ? error.message : 'Failed to pair this device with RoachTail',
      })
    }
  }

  async affectRoachTail({ request, response }: HttpContext) {
    const payload = request.body() as RoachTailActionInput
    const action = payload.action?.trim() as RoachTailActionInput['action']
    const peerRequest = this.isPeerRoachTailRequest(request)
    const peerID = this.roachTailPeerID(request)

    if (
      !action ||
      ![
        'enable',
        'disable',
        'refresh-join-code',
        'clear-peers',
        'set-relay-host',
        'register-peer',
        'remove-peer',
      ].includes(action)
    ) {
      return response.status(400).json({
        error:
          'RoachTail action must be enable, disable, refresh-join-code, clear-peers, set-relay-host, register-peer, or remove-peer.',
      })
    }

    if (peerRequest) {
      const selfScopedAction = action === 'register-peer' || action === 'remove-peer'
      const peerCanAct = action === 'enable' || action === 'disable' || selfScopedAction

      if (!peerCanAct) {
        return response.status(403).json({
          error: 'This RoachTail action requires the desktop companion token.',
        })
      }

      if (selfScopedAction && peerID) {
        const requestedPeerID = payload.peerId?.trim()
        if (requestedPeerID && requestedPeerID !== peerID) {
          return response.status(403).json({
            error: 'Peer-scoped RoachTail changes can only target the paired device token.',
          })
        }
        payload.peerId = peerID
      }
    }

    try {
      const state = await this.mutateRoachTailState(action, payload)
      const actionLabel =
        action === 'refresh-join-code'
          ? 'RoachTail join code refreshed.'
          : action === 'clear-peers'
            ? 'RoachTail peers cleared.'
            : action === 'set-relay-host'
              ? 'RoachTail relay host updated.'
              : action === 'register-peer'
                ? 'Device linked to RoachTail.'
                : action === 'remove-peer'
                  ? 'RoachTail peer removed.'
                  : action === 'enable'
                    ? 'RoachTail enabled.'
                    : 'RoachTail disabled.'

      return {
        success: true,
        message: actionLabel,
        state,
      }
    } catch (error) {
      return response.status(400).json({
        error: error instanceof Error ? error.message : 'Failed to update RoachTail state',
      })
    }
  }

  async affectRoachSync({ request, response }: HttpContext) {
    const payload = request.body() as RoachSyncActionInput
    const action = payload.action?.trim() as RoachSyncActionInput['action']

    if (!action || !['enable', 'disable', 'refresh', 'set-folder-path', 'clear-peers'].includes(action)) {
      return response.status(400).json({
        error: 'RoachSync action must be enable, disable, refresh, set-folder-path, or clear-peers.',
      })
    }

    try {
      const state = await this.mutateRoachSyncState(action, payload)
      return {
        success: true,
        message:
          action === 'enable'
            ? 'RoachSync enabled.'
            : action === 'disable'
              ? 'RoachSync disabled.'
              : action === 'set-folder-path'
                ? 'RoachSync folder updated.'
                : action === 'clear-peers'
                  ? 'RoachSync peers cleared.'
                  : 'RoachSync refreshed.',
        state,
      }
    } catch (error) {
      return response.status(400).json({
        error: error instanceof Error ? error.message : 'Failed to update RoachSync state',
      })
    }
  }

  async affectAccount({ request, response }: HttpContext) {
    const payload = request.body() as RoachNetAccountActionInput
    const action = payload.action?.trim() as RoachNetAccountActionInput['action']

    if (!action || !['link', 'unlink', 'refresh'].includes(action)) {
      return response.status(400).json({
        error: 'Account action must be link, unlink, or refresh.',
      })
    }

    try {
      const state = await this.mutateAccountState(action, payload)
      return {
        success: true,
        message:
          action === 'link'
            ? 'RoachNet account linked.'
            : action === 'unlink'
              ? 'RoachNet account unlinked.'
              : 'RoachNet account refreshed.',
        state,
      }
    } catch (error) {
      return response.status(400).json({
        error: error instanceof Error ? error.message : 'Failed to update RoachNet account state',
      })
    }
  }

  async vault({ request }: HttpContext) {
    return this.vaultPayload(request)
  }

  async affectService({ request, response }: HttpContext) {
    try {
      const payload = request.body() as CompanionServiceActionInput
      const serviceName = payload.serviceName?.trim()
      const action = payload.action?.trim()

      if (!serviceName) {
        return response.status(400).json({ error: 'Service name is required' })
      }

      if (!action || !['start', 'stop', 'restart'].includes(action)) {
        return response
          .status(400)
          .json({ error: 'Service action must be start, stop, or restart' })
      }

      const result = await this.relayJson('/api/system/services/affect', request, {
        method: 'POST',
        body: JSON.stringify({
          service_name: serviceName,
          action,
        }),
      })

      return {
        ok: true,
        serviceName,
        action,
        result,
      }
    } catch (error) {
      return response.status(400).json({
        error: error instanceof Error ? error.message : 'Failed to affect companion service',
      })
    }
  }

  async sessionsIndex() {
    return this.chatService.getAllSessions()
  }

  async sessionsShow({ params, response }: HttpContext) {
    const sessionId = Number(params.id)
    const session = Number.isFinite(sessionId) ? await this.chatService.getSession(sessionId) : null

    if (!session) {
      return response.status(404).json({ error: 'Session not found' })
    }

    return session
  }

  async sessionsStore({ request, response }: HttpContext) {
    const payload = request.body() as { title?: string; model?: string }
    const title = payload.title?.trim() || 'New Chat'
    const model = payload.model?.trim()

    try {
      const session = await this.chatService.createSession(title, model)
      return response.status(201).json(session)
    } catch (error) {
      return response.status(201).json(this.syntheticSession(title, model))
    }
  }

  async sendMessage({ request, response }: HttpContext) {
    try {
      const payload = request.body() as {
        sessionId?: number | string
        content?: string
        model?: string
        messages?: CompanionChatInputMessage[]
        images?: string[]
        visionSummary?: string
      }
      const content = payload.content?.trim()
      if (!content) {
        return response.status(400).json({ error: 'Message content is required' })
      }
      const sanitizedImages = this.normalizeCompanionImages(payload.images)
      const storedContent = this.composeCompanionContent(
        content,
        payload.visionSummary,
        sanitizedImages.length
      )

      let sessionId = Number(payload.sessionId)
      let session = Number.isFinite(sessionId) ? await this.chatService.getSession(sessionId) : null

      if (!session) {
        try {
          const created = await this.chatService.createSession('New Chat', payload.model?.trim())
          sessionId = Number(created.id)
          session = await this.chatService.getSession(sessionId)
        } catch {
          session = null
        }
      }

      if (!session) {
        return this.sendEphemeralMessage(payload, content)
      }

      const selectedModel =
        payload.model?.trim() ||
        session.model ||
        process.env.ROACHNET_ROACHCLAW_DEFAULT_MODEL ||
        'qwen2.5-coder:1.5b'
      const shouldAttachImages =
        sanitizedImages.length > 0 && !selectedModel.trim().toLowerCase().endsWith(':cloud')

      const userMessage = await this.chatService.addMessage(sessionId, 'user', storedContent)
      const refreshedSession = await this.chatService.getSession(sessionId)
      if (!refreshedSession) {
        throw new Error('Failed to reload the updated chat session')
      }

      const ollamaMessages = refreshedSession.messages.map((message) => ({
        role: message.role,
        content: message.content,
      }))
      if (shouldAttachImages && ollamaMessages.length > 0) {
        ollamaMessages[ollamaMessages.length - 1] = {
          ...ollamaMessages[ollamaMessages.length - 1],
          images: sanitizedImages,
        } as (typeof ollamaMessages)[number]
      }

      const ollamaResponse = await this.ollamaService.chat({
        model: selectedModel,
        messages: ollamaMessages as never,
        stream: false,
      })

      const assistantContent = ollamaResponse?.message?.content?.trim()
      if (!assistantContent) {
        throw new Error('RoachClaw returned an empty response')
      }

      const assistantMessage = await this.chatService.addMessage(
        sessionId,
        'assistant',
        assistantContent
      )
      await this.chatService.updateSession(sessionId, { model: selectedModel })

      const messageCount = await this.chatService.getMessageCount(sessionId)
      let title = refreshedSession.title
      if ((!title || title === 'New Chat') && messageCount <= 2) {
        title =
          (await this.chatService.generateTitle(sessionId, content, assistantContent)) ?? title
      }

      const finalSession = await this.chatService.getSession(sessionId)

      return {
        session: finalSession
          ? {
              id: finalSession.id,
              title: finalSession.title,
              model: finalSession.model || selectedModel,
              timestamp: finalSession.timestamp,
            }
          : {
              id: String(sessionId),
              title: title || 'New Chat',
              model: selectedModel,
              timestamp: new Date(),
            },
        userMessage,
        assistantMessage,
      }
    } catch (error) {
      return response.status(500).json({
        error: error instanceof Error ? error.message : 'Failed to send companion message',
      })
    }
  }

  private async sendEphemeralMessage(
    payload: {
      sessionId?: number | string
      content?: string
      model?: string
      messages?: CompanionChatInputMessage[]
      images?: string[]
      visionSummary?: string
    },
    content: string
  ) {
    const selectedModel =
      payload.model?.trim() || process.env.ROACHNET_ROACHCLAW_DEFAULT_MODEL || 'qwen2.5-coder:1.5b'
    const sanitizedImages = this.normalizeCompanionImages(payload.images)
    const shouldAttachImages =
      sanitizedImages.length > 0 && !selectedModel.trim().toLowerCase().endsWith(':cloud')
    const enrichedContent = this.composeCompanionContent(
      content,
      payload.visionSummary,
      sanitizedImages.length
    )

    const history = Array.isArray(payload.messages)
      ? payload.messages
          .filter((message) => message && typeof message === 'object')
          .map((message) => ({
            role: ['system', 'user', 'assistant'].includes(String(message.role))
              ? (message.role as 'system' | 'user' | 'assistant')
              : 'user',
            content: String(message.content || '').trim(),
          }))
          .filter((message) => message.content.length > 0)
          .slice(-20)
      : []

    const userMessage = this.syntheticMessage('user', enrichedContent)
    const outboundMessages = [...history, { role: 'user' as const, content: enrichedContent }]
    if (shouldAttachImages) {
      outboundMessages[outboundMessages.length - 1] = {
        ...outboundMessages[outboundMessages.length - 1],
        images: sanitizedImages,
      } as (typeof outboundMessages)[number]
    }

    const ollamaResponse = await this.ollamaService.chat({
      model: selectedModel,
      messages: outboundMessages as never,
      stream: false,
    })

    const assistantContent = ollamaResponse?.message?.content?.trim()
    if (!assistantContent) {
      throw new Error('RoachClaw returned an empty response')
    }

    const assistantMessage = this.syntheticMessage('assistant', assistantContent)
    const sessionTitle =
      history.find((message) => message.role === 'user')?.content?.slice(0, 57) ||
      content.slice(0, 57) ||
      'New Chat'

    return {
      session: this.syntheticSession(sessionTitle, selectedModel, String(payload.sessionId || '')),
      userMessage,
      assistantMessage,
    }
  }

  private composeCompanionContent(content: string, visionSummary?: string, imageCount = 0) {
    const trimmedSummary = visionSummary?.trim()
    if (!trimmedSummary) {
      return content
    }

    return `${content}\n\n[Vision attachment${imageCount > 1 ? 's' : ''}: ${imageCount}]\n${trimmedSummary}`
  }

  private normalizeCompanionImages(images: unknown): string[] {
    if (!Array.isArray(images)) {
      return []
    }

    return images
      .map((image) => String(image || '').trim())
      .filter((image) => image.length > 0)
      .slice(0, 4)
  }

  async install({ request, response }: HttpContext) {
    try {
      const action = this.normalizeInstallInput(request.body() as CompanionInstallInput)
      const result = await this.dispatchInstallAction(action, request)
      return {
        ok: true,
        action: action.action,
        result,
      }
    } catch (error) {
      return response.status(400).json({
        error: error instanceof Error ? error.message : 'Failed to queue companion install',
      })
    }
  }

  private async runtimePayload(request: HttpContext['request']) {
    const issues: RelayIssue[] = []
    const [systemInfo, providers, roachClaw, services, downloads, installedModels, account, roachTail, roachSync] =
      await Promise.all([
        this.relayJsonFallback('/api/system/info', request, null, issues),
        this.relayJsonFallback('/api/system/ai/providers', request, { providers: {} }, issues),
        this.relayJsonFallback(
          '/api/roachclaw/status',
          request,
          {
            label: 'RoachClaw',
            ready: false,
            error: 'RoachClaw is still warming up.',
            installedModels: [],
          },
          issues
        ),
        this.relayJsonFallback('/api/system/services', request, [], issues),
        this.relayJsonFallback('/api/downloads/jobs', request, [], issues),
        this.relayJsonFallback('/api/ollama/installed-models', request, [], issues),
        this.accountPayload(),
        this.roachTailPayload({
          hideJoinCode: this.isPeerRoachTailRequest(request),
        }),
        this.roachSyncPayload(),
      ])

    return {
      systemInfo,
      providers,
      roachClaw,
      account,
      roachTail,
      roachSync,
      services,
      downloads,
      installedModels,
      issues,
    }
  }

  private async vaultPayload(request: HttpContext['request']) {
    const issues: RelayIssue[] = []
    const [knowledgeFiles, siteArchives, roachBrain, atlasShelves, studyShelves, referenceShelves] =
      await Promise.all([
      this.relayJsonFallback('/api/rag/files', request, { files: [] }, issues),
      this.relayJsonFallback('/api/site-archives', request, { archives: [] }, issues),
      this.readRoachBrainMemories(),
      this.localPayloadFallback('/api/maps/collections', [], issues, async () =>
        this.buildAtlasShelves()
      ),
      this.localPayloadFallback('/api/zim/categories', [], issues, async () =>
        this.buildStudyShelves()
      ),
      this.localPayloadFallback('/api/zim/wikipedia/state', [], issues, async () =>
        this.buildReferenceShelves()
      ),
    ])

    return {
      knowledgeFiles: knowledgeFiles?.files ?? [],
      siteArchives: siteArchives?.archives ?? [],
      roachBrain,
      atlasShelves,
      studyShelves,
      referenceShelves,
      issues,
    }
  }

  private async buildAtlasShelves() {
    const collections = await this.mapService.listCuratedCollections()

    return collections.map((collection) => ({
      id: collection.slug,
      title: collection.name,
      detail:
        collection.description ||
        'Offline regional map pack ready to live beside the rest of the Vault.',
      kind: 'atlas',
      status: collection.all_installed
        ? 'Ready on shelf'
        : `${collection.installed_count}/${collection.total_count} ready`,
      actionLabel: collection.all_installed ? 'Open atlas' : 'Add to Vault',
      routePath: '/maps',
      installed: collection.all_installed,
    }))
  }

  private async buildStudyShelves() {
    const categories = await this.zimService.listCuratedCategories()

    return categories.map((category) => ({
      id: category.slug,
      title: category.name,
      detail:
        category.description || 'Structured offline coursework ready for the study shelf.',
      kind: 'study',
      status: category.installedTierSlug
        ? `Ready · ${category.installedTierSlug}`
        : 'Download recommended',
      actionLabel: category.installedTierSlug ? 'Open study shelf' : 'Add to Vault',
      routePath: '/docs/home',
      installed: Boolean(category.installedTierSlug),
    }))
  }

  private async buildReferenceShelves() {
    const wikipediaState = await this.zimService.getWikipediaState()
    const currentOptionId = wikipediaState.currentSelection?.optionId

    return wikipediaState.options
      .filter((option) => option.id !== 'none')
      .map((option) => ({
        id: option.id,
        title: option.name,
        detail: option.description || 'Offline reference package ready for the shelf.',
        kind: 'reference',
        status: option.id === currentOptionId ? 'Current reference' : 'Available',
        actionLabel: option.id === currentOptionId ? 'Open reference' : 'Set reference',
        routePath: '/docs/home',
        installed: option.id === currentOptionId,
      }))
  }

  private async accountPayload(): Promise<RoachNetAccountStateRecord> {
    return this.readAccountState()
  }

  private async readAccountState(): Promise<RoachNetAccountStateRecord> {
    const storagePath = this.storagePath()
    const portalUrl =
      process.env.ROACHNET_ACCOUNT_PORTAL_URL?.trim() || 'https://accounts.roachnet.org/'
    const aliasHost = this.roachNetLocalHost()
    const statePath = storagePath ? path.join(storagePath, 'vault', 'account', 'state.json') : null
    const roachTail = await this.readRoachTailStateRaw()
    const roachSync = await this.readRoachSyncState()
    const fallback: RoachNetAccountStateRecord = {
      linked: false,
      provider: 'RoachNet Account',
      portalUrl,
      accountId: null,
      email: null,
      displayName: null,
      status: 'local-only',
      settingsSyncEnabled: roachSync.enabled,
      savedAppsSyncEnabled: roachSync.enabled,
      hostedChatEnabled: roachTail.enabled,
      aliasHost,
      bridgeUrl: this.sanitizeUserFacingUrl(
        roachTail.runtimeTunnelUrl ?? roachTail.advertisedUrl,
        38111
      ),
      runtimeOrigin: this.sanitizeUserFacingUrl(
        roachTail.runtimeOrigin ?? this.localBaseUrl().toString(),
        process.env.PORT?.trim() || '8080'
      ),
      linkedAt: null,
      lastSeenAt: null,
      lastUpdatedAt: new Date().toISOString(),
      notes: [
        'Use one RoachNet account to tie web chat, saved app picks, and future synced settings back to your devices.',
        roachTail.enabled
          ? 'RoachTail is already armed, so a linked account can follow the same private device lane.'
          : 'Arm RoachTail when you want account-linked devices to stay off raw public addresses.',
      ],
    }

    if (!statePath) {
      return fallback
    }

    try {
      const raw = await readFile(statePath, 'utf8')
      const parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== 'object') {
        return fallback
      }

      return {
        linked: typeof parsed.linked === 'boolean' ? parsed.linked : fallback.linked,
        provider: typeof parsed.provider === 'string' ? parsed.provider : fallback.provider,
        portalUrl: typeof parsed.portalUrl === 'string' ? parsed.portalUrl : fallback.portalUrl,
        accountId: typeof parsed.accountId === 'string' ? parsed.accountId : fallback.accountId,
        email: typeof parsed.email === 'string' ? parsed.email : fallback.email,
        displayName:
          typeof parsed.displayName === 'string' ? parsed.displayName : fallback.displayName,
        status: typeof parsed.status === 'string' ? parsed.status : fallback.status,
        settingsSyncEnabled:
          typeof parsed.settingsSyncEnabled === 'boolean'
            ? parsed.settingsSyncEnabled
            : fallback.settingsSyncEnabled,
        savedAppsSyncEnabled:
          typeof parsed.savedAppsSyncEnabled === 'boolean'
            ? parsed.savedAppsSyncEnabled
            : fallback.savedAppsSyncEnabled,
        hostedChatEnabled:
          typeof parsed.hostedChatEnabled === 'boolean'
            ? parsed.hostedChatEnabled
            : fallback.hostedChatEnabled,
        aliasHost: typeof parsed.aliasHost === 'string' ? parsed.aliasHost : fallback.aliasHost,
        bridgeUrl: this.sanitizeUserFacingUrl(
          typeof parsed.bridgeUrl === 'string' ? parsed.bridgeUrl : fallback.bridgeUrl,
          38111
        ),
        runtimeOrigin: this.sanitizeUserFacingUrl(
          typeof parsed.runtimeOrigin === 'string' ? parsed.runtimeOrigin : fallback.runtimeOrigin,
          process.env.PORT?.trim() || '8080'
        ),
        linkedAt: typeof parsed.linkedAt === 'string' ? parsed.linkedAt : fallback.linkedAt,
        lastSeenAt:
          typeof parsed.lastSeenAt === 'string' ? parsed.lastSeenAt : fallback.lastSeenAt,
        lastUpdatedAt:
          typeof parsed.lastUpdatedAt === 'string'
            ? parsed.lastUpdatedAt
            : fallback.lastUpdatedAt,
        notes: Array.isArray(parsed.notes)
          ? parsed.notes.filter((value: unknown) => typeof value === 'string')
          : fallback.notes,
      }
    } catch {
      return fallback
    }
  }

  private async mutateAccountState(
    action: NonNullable<RoachNetAccountActionInput['action']>,
    payload: RoachNetAccountActionInput
  ): Promise<RoachNetAccountStateRecord> {
    const storagePath = this.storagePath()
    if (!storagePath) {
      throw new Error('RoachNet account state cannot be stored until the contained storage lane exists.')
    }

    const statePath = path.join(storagePath, 'vault', 'account', 'state.json')
    await mkdir(path.dirname(statePath), { recursive: true })

    const current = await this.readAccountState()
    const now = new Date().toISOString()
    const next: RoachNetAccountStateRecord = {
      ...current,
      portalUrl: payload.portalUrl?.trim() || current.portalUrl,
      aliasHost: this.roachNetLocalHost(),
      bridgeUrl: this.sanitizeUserFacingUrl(current.bridgeUrl, 38111),
      runtimeOrigin: this.sanitizeUserFacingUrl(
        current.runtimeOrigin ?? this.localBaseUrl().toString(),
        process.env.PORT?.trim() || '8080'
      ),
      lastSeenAt: now,
      lastUpdatedAt: now,
      notes: [...current.notes],
    }

    switch (action) {
      case 'link':
        next.linked = true
        next.status = 'linked'
        next.accountId = payload.accountId?.trim() || current.accountId
        next.email = payload.email?.trim() || current.email
        next.displayName = payload.displayName?.trim() || current.displayName
        next.settingsSyncEnabled = payload.settingsSyncEnabled ?? current.settingsSyncEnabled
        next.savedAppsSyncEnabled = payload.savedAppsSyncEnabled ?? current.savedAppsSyncEnabled
        next.hostedChatEnabled = payload.hostedChatEnabled ?? true
        next.linkedAt = current.linkedAt ?? now
        next.notes = [
          'This device is linked to the RoachNet account lane.',
          'Web chat, saved app picks, and future synced settings can hang off the same contained stack without exposing raw host addresses.',
        ]
        break
      case 'unlink':
        next.linked = false
        next.status = 'local-only'
        next.accountId = null
        next.email = null
        next.displayName = null
        next.settingsSyncEnabled = false
        next.savedAppsSyncEnabled = false
        next.hostedChatEnabled = false
        next.linkedAt = null
        next.notes = [
          'The RoachNet account link was cleared from this contained install.',
          'RoachTail and RoachSync can still run locally until you link another account.',
        ]
        break
      case 'refresh':
        next.status = next.linked ? 'linked' : 'local-only'
        next.notes = next.linked
          ? [
              'RoachNet refreshed the local account snapshot for this device.',
              'Use the Accounts page when you want to rotate credentials or review linked devices.',
            ]
          : [
              'No linked account is stored in this install yet.',
              'Open the Accounts page when you are ready to tie web chat and device sync back to a RoachNet identity.',
            ]
        break
    }

    await writeFile(statePath, JSON.stringify(next, null, 2), 'utf8')
    return next
  }

  private localBaseUrl(request?: HttpContext['request']) {
    if (request) {
      const requestedUrl = new URL(`${request.protocol()}://${request.host()}`)
      if (this.isLoopbackHost(requestedUrl.hostname)) {
        return new URL(this.publicLoopbackUrl(requestedUrl.port || '8080', requestedUrl.pathname))
      }
      return requestedUrl
    }

    const origin = process.env.URL?.trim()
    if (origin) {
      const parsedOrigin = new URL(origin)
      if (this.isLoopbackHost(parsedOrigin.hostname)) {
        return new URL(this.publicLoopbackUrl(parsedOrigin.port || '8080', parsedOrigin.pathname))
      }
      return parsedOrigin
    }

    const host = process.env.HOST?.trim() || this.roachNetLocalHost()
    const port = process.env.PORT?.trim() || '8080'
    return new URL(`http://${host}:${port}`)
  }

  private isLoopbackHost(host: string) {
    const normalized = host.trim().replace(/^\[|\]$/g, '').toLowerCase()
    return ['localhost', '127.0.0.1', '::1', '0.0.0.0', '::'].includes(normalized)
  }

  private roachNetLocalHost() {
    return process.env.ROACHNET_LOCAL_HOSTNAME?.trim() || 'RoachNet'
  }

  private publicLoopbackUrl(port: string | number, pathname = '') {
    const host = this.roachNetLocalHost()
    const wrappedHost =
      host.includes(':') && !host.startsWith('[')
        ? `[${host}]`
        : host

    return `http://${wrappedHost}:${String(port)}${pathname}`
  }

  private isIPAddress(host: string) {
    const normalized = host.trim().replace(/^\[|\]$/g, '')
    return (
      /^(\d{1,3}\.){3}\d{1,3}$/.test(normalized) ||
      /^[0-9a-f:]+$/i.test(normalized)
    )
  }

  private sanitizeUserFacingUrl(rawValue?: string | null, fallbackPort?: string | number) {
    const trimmed = rawValue?.trim()
    if (!trimmed) {
      return fallbackPort != null ? this.publicLoopbackUrl(fallbackPort) : null
    }

    try {
      const parsed = new URL(trimmed)
      if (this.isLoopbackHost(parsed.hostname) || this.isIPAddress(parsed.hostname)) {
        parsed.hostname = this.roachNetLocalHost()
      }
      return parsed.toString()
    } catch {
      if (this.isLoopbackHost(trimmed) || this.isIPAddress(trimmed)) {
        return this.publicLoopbackUrl(fallbackPort ?? '38111')
      }
      return trimmed
    }
  }

  private sanitizePeerEndpoint(endpoint?: string | null) {
    const trimmed = endpoint?.trim()
    if (!trimmed) {
      return null
    }

    const aliasHost = this.roachNetLocalHost()

    try {
      const parsed = new URL(trimmed)
      if (this.isLoopbackHost(parsed.hostname) || this.isIPAddress(parsed.hostname)) {
        return aliasHost
      }
      return parsed.host || parsed.hostname
    } catch {
      if (this.isLoopbackHost(trimmed) || this.isIPAddress(trimmed)) {
        return aliasHost
      }
      return trimmed
    }
  }

  private async relayJson(pathname: string, request?: HttpContext['request'], init?: RequestInit) {
    const url = new URL(pathname, this.localBaseUrl(request))
    const relayRequest = new Request(url, {
      ...init,
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        ...(init?.headers || {}),
      },
    })

    const response = await fetch(relayRequest)
    if (!response.ok) {
      throw new Error(`Companion relay failed for ${pathname} (${response.status})`)
    }

    if (response.status === 204) {
      return null
    }

    const text = await response.text()
    return text ? JSON.parse(text) : null
  }

  private async relayJsonFallback<T>(
    pathname: string,
    request: HttpContext['request'],
    fallback: T,
    issues: RelayIssue[]
  ): Promise<T> {
    try {
      const value = await this.relayJson(pathname, request)
      return (value ?? fallback) as T
    } catch (error) {
      issues.push({
        path: pathname,
        error: error instanceof Error ? error.message : 'Relay failed',
      })
      return fallback
    }
  }

  private async localPayloadFallback<T>(
    label: string,
    fallback: T,
    issues: RelayIssue[],
    operation: () => Promise<T>
  ): Promise<T> {
    try {
      return await operation()
    } catch (error) {
      issues.push({
        path: label,
        error: error instanceof Error ? error.message : 'Local payload failed',
      })
      return fallback
    }
  }

  private normalizeInstallInput(input: CompanionInstallInput): CompanionInstallAction {
    if (input.installUrl) {
      const url = new URL(input.installUrl)
      const route = (url.host || url.pathname.replace(/\//g, '')).toLowerCase()

      if (url.protocol !== 'roachnet:' || route !== 'install-content') {
        throw new Error('Companion install URLs must use the RoachNet install-content scheme')
      }

      const query = Object.fromEntries(url.searchParams.entries())
      return {
        action: query.action || query.type || '',
        slug: query.slug,
        category: query.category,
        tier: query.tier,
        resource: query.resource || query.resourceId,
        option: query.option || query.optionId,
        model: query.model,
        url: query.url,
        filetype: query.filetype || query.resourceType,
      }
    }

    return {
      action: input.action || input.type || '',
      slug: input.slug,
      category: input.category,
      tier: input.tier,
      resource: input.resource || input.resourceId,
      option: input.option || input.optionId,
      model: input.model,
      url: input.url,
      filetype: input.filetype || input.resourceType,
      metadata: input.metadata,
    }
  }

  private async dispatchInstallAction(
    input: CompanionInstallAction,
    request: HttpContext['request']
  ) {
    switch (input.action) {
      case 'base-map-assets':
        return this.relayJson('/api/maps/download-base-assets', request, { method: 'POST' })
      case 'map-collection':
        if (!input.slug) {
          throw new Error('Map collection installs need a collection slug')
        }
        return this.relayJson('/api/maps/download-collection', request, {
          method: 'POST',
          body: JSON.stringify({ slug: input.slug }),
        })
      case 'education-tier':
        if (!input.category || !input.tier) {
          throw new Error('Education tier installs need category and tier slugs')
        }
        return this.relayJson('/api/zim/download-category-tier', request, {
          method: 'POST',
          body: JSON.stringify({ categorySlug: input.category, tierSlug: input.tier }),
        })
      case 'education-resource':
        if (!input.category || !input.resource) {
          throw new Error('Education resource installs need a category and resource id')
        }
        return this.relayJson('/api/zim/download-category-resource', request, {
          method: 'POST',
          body: JSON.stringify({ categorySlug: input.category, resourceId: input.resource }),
        })
      case 'wikipedia-option':
        if (!input.option) {
          throw new Error('Wikipedia installs need an option id')
        }
        return this.relayJson('/api/zim/wikipedia/select', request, {
          method: 'POST',
          body: JSON.stringify({ optionId: input.option }),
        })
      case 'roachclaw-model':
        if (!input.model) {
          throw new Error('RoachClaw model installs need a model id')
        }
        const queuedModel = await this.relayJson('/api/ollama/models', request, {
          method: 'POST',
          body: JSON.stringify({ model: input.model }),
        })
        const appliedModel = await this.relayJson('/api/roachclaw/apply', request, {
          method: 'POST',
          body: JSON.stringify({ model: input.model }),
        })
        return { queuedModel, appliedModel }
      case 'direct-download':
        if (!input.url) {
          throw new Error('Direct download installs need a URL')
        }
        if (
          (input.filetype || '').toLowerCase() === 'map' ||
          (input.filetype || '').toLowerCase() === 'pmtiles'
        ) {
          return this.relayJson('/api/maps/download-remote', request, {
            method: 'POST',
            body: JSON.stringify({ url: input.url }),
          })
        }
        return this.relayJson('/api/zim/download-remote', request, {
          method: 'POST',
          body: JSON.stringify({ url: input.url, metadata: input.metadata }),
        })
      default:
        throw new Error(`Unknown companion install action: ${input.action || 'missing action'}`)
    }
  }

  private async readRoachBrainMemories(): Promise<RoachBrainMemoryRecord[]> {
    const storagePath = this.storagePath()

    if (!storagePath) {
      return []
    }

    const catalogPath = path.join(storagePath, 'vault', 'roachbrain', 'memories.json')

    try {
      const raw = await readFile(catalogPath, 'utf8')
      const parsed = JSON.parse(raw)
      if (!Array.isArray(parsed)) {
        return []
      }

      return parsed
        .filter((entry) => entry && typeof entry === 'object')
        .map((entry) => ({
          id: String(entry.id || ''),
          title: String(entry.title || 'RoachBrain note'),
          summary: String(entry.summary || ''),
          source: String(entry.source || 'RoachBrain'),
          tags: Array.isArray(entry.tags) ? entry.tags.map((tag: unknown) => String(tag)) : [],
          pinned: Boolean(entry.pinned),
          lastAccessedAt: String(entry.lastAccessedAt || entry.createdAt || ''),
        }))
        .filter((entry) => entry.id && entry.title)
        .slice(0, 40)
    } catch {
      return []
    }
  }

  private async roachTailPayload(
    options: RoachTailStateSanitizeOptions = {}
  ): Promise<RoachTailStateRecord> {
    const current = await this.readRoachTailStateRaw()
    const statePath = this.roachTailStatePath()

    if (current.enabled && (!this.isRoachTailJoinCodeFresh(current) || !current.joinCode) && statePath) {
      const joinCodeBundle = this.issueRoachTailJoinCode()
      current.joinCode = joinCodeBundle.joinCode
      current.joinCodeIssuedAt = joinCodeBundle.issuedAt
      current.joinCodeExpiresAt = joinCodeBundle.expiresAt
      current.lastUpdatedAt = new Date().toISOString()
      await mkdir(path.dirname(statePath), { recursive: true })
      await writeFile(statePath, JSON.stringify(current, null, 2), 'utf8')
    }

    return this.sanitizeRoachTailState(current, options)
  }

  private async roachSyncPayload(): Promise<RoachSyncStateRecord> {
    return this.readRoachSyncState()
  }

  private async readRoachTailStateRaw(): Promise<InternalRoachTailStateRecord> {
    const statePath = this.roachTailStatePath()
    const advertisedUrl =
      process.env.ROACHNET_COMPANION_ADVERTISED_URL?.trim() ||
      process.env.ROACHNET_COMPANION_TARGET_URL?.trim() ||
      null
    const relayHost = process.env.ROACHTAIL_RELAY_HOST?.trim() || null
    const configuredDeviceName =
      process.env.ROACHTAIL_DEVICE_NAME?.trim() ||
      process.env.ROACHNET_DEVICE_NAME?.trim() ||
      'RoachNet desktop'
    const configuredNetworkName = process.env.ROACHTAIL_NETWORK_NAME?.trim() || 'RoachTail'
    const configuredDeviceId =
      process.env.ROACHTAIL_DEVICE_ID?.trim() || `roachnet-${randomUUID().slice(0, 8)}`
    const configuredJoinCode = process.env.ROACHTAIL_JOIN_CODE?.trim() || null
    const enabled =
      process.env.ROACHTAIL_ENABLED === '1' || process.env.ROACHNET_COMPANION_ENABLED === '1'

    const fallback: InternalRoachTailStateRecord = {
      enabled,
      networkName: configuredNetworkName,
      deviceName: configuredDeviceName,
      deviceId: configuredDeviceId,
      status: enabled ? 'armed' : 'local-only',
      transportMode: relayHost ? 'tailnet-relay' : 'local-bridge',
      secureOverlay: Boolean(relayHost),
      relayHost,
      advertisedUrl: advertisedUrl || this.buildRoachTailAdvertisedURL(relayHost, this.companionBridgeURL()),
      runtimeOrigin: this.localBaseUrl().toString(),
      runtimeTunnelUrl: this.buildRoachTailRuntimeURL(relayHost, advertisedUrl || this.companionBridgeURL()),
      joinCode: configuredJoinCode,
      joinCodeIssuedAt: configuredJoinCode ? new Date().toISOString() : null,
      joinCodeExpiresAt: configuredJoinCode
        ? new Date(Date.now() + ROACHTAIL_JOIN_CODE_TTL_MS).toISOString()
        : null,
      pairingPayload: null,
      pairingIssuedAt: configuredJoinCode ? new Date().toISOString() : null,
      lastUpdatedAt: new Date().toISOString(),
      notes: [
        'RoachTail keeps the companion lane ready for private device-to-device control.',
        enabled
          ? 'This desktop is ready to advertise a private control lane to linked devices.'
          : 'Enable RoachTail to group mobile and desktop lanes behind a private overlay.',
        relayHost
          ? 'The advertised bridge is already pointing at the secure relay host instead of the raw local address.'
          : 'Add a RoachTail relay host when you want phones and remote devices to stay off the raw machine IP.',
      ],
      peers: [],
    }

    if (!statePath) {
      return fallback
    }

    try {
      const raw = await readFile(statePath, 'utf8')
      const parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== 'object') {
        return fallback
      }

      const peers = Array.isArray(parsed.peers)
        ? parsed.peers
            .filter((entry: unknown) => entry && typeof entry === 'object')
            .map((entry: Record<string, unknown>, index: number) => ({
              id: typeof entry.id === 'string' ? entry.id : `peer-${index}`,
              name: typeof entry.name === 'string' ? entry.name : `Linked device ${index + 1}`,
              platform: typeof entry.platform === 'string' ? entry.platform : 'device',
              status: typeof entry.status === 'string' ? entry.status : 'linked',
              endpoint: typeof entry.endpoint === 'string' ? entry.endpoint : null,
              lastSeenAt: typeof entry.lastSeenAt === 'string' ? entry.lastSeenAt : null,
              allowsExitNode: Boolean(entry.allowsExitNode),
              tags: Array.isArray(entry.tags)
                ? entry.tags.filter((value: unknown) => typeof value === 'string')
                : [],
              tokenHash: typeof entry.tokenHash === 'string' ? entry.tokenHash : null,
              pairedAt: typeof entry.pairedAt === 'string' ? entry.pairedAt : null,
              appVersion: typeof entry.appVersion === 'string' ? entry.appVersion : null,
            }))
        : []

      return {
        enabled: typeof parsed.enabled === 'boolean' ? parsed.enabled : fallback.enabled,
        networkName:
          typeof parsed.networkName === 'string' ? parsed.networkName : fallback.networkName,
        deviceName:
          typeof parsed.deviceName === 'string' ? parsed.deviceName : fallback.deviceName,
        deviceId: typeof parsed.deviceId === 'string' ? parsed.deviceId : fallback.deviceId,
        status:
          typeof parsed.status === 'string'
            ? parsed.status
            : peers.length > 0
              ? 'connected'
              : fallback.status,
        transportMode:
          typeof parsed.transportMode === 'string'
            ? parsed.transportMode
            : fallback.transportMode,
        secureOverlay:
          typeof parsed.secureOverlay === 'boolean'
            ? parsed.secureOverlay
            : fallback.secureOverlay,
        relayHost: typeof parsed.relayHost === 'string' ? parsed.relayHost : fallback.relayHost,
        advertisedUrl:
          typeof parsed.advertisedUrl === 'string'
            ? parsed.advertisedUrl
            : fallback.advertisedUrl,
        runtimeOrigin:
          typeof parsed.runtimeOrigin === 'string' ? parsed.runtimeOrigin : fallback.runtimeOrigin,
        runtimeTunnelUrl:
          typeof parsed.runtimeTunnelUrl === 'string'
            ? parsed.runtimeTunnelUrl
            : fallback.runtimeTunnelUrl,
        joinCode: typeof parsed.joinCode === 'string' ? parsed.joinCode : fallback.joinCode,
        joinCodeIssuedAt:
          typeof parsed.joinCodeIssuedAt === 'string'
            ? parsed.joinCodeIssuedAt
            : fallback.joinCodeIssuedAt,
        joinCodeExpiresAt:
          typeof parsed.joinCodeExpiresAt === 'string'
            ? parsed.joinCodeExpiresAt
            : fallback.joinCodeExpiresAt,
        pairingPayload:
          typeof parsed.pairingPayload === 'string' ? parsed.pairingPayload : fallback.pairingPayload,
        pairingIssuedAt:
          typeof parsed.pairingIssuedAt === 'string'
            ? parsed.pairingIssuedAt
            : fallback.pairingIssuedAt,
        lastUpdatedAt:
          typeof parsed.lastUpdatedAt === 'string'
            ? parsed.lastUpdatedAt
            : fallback.lastUpdatedAt,
        notes: Array.isArray(parsed.notes)
          ? parsed.notes.filter((value: unknown) => typeof value === 'string')
          : fallback.notes,
        peers,
      }
    } catch {
      return fallback
    }
  }

  private sanitizeRoachTailState(
    state: InternalRoachTailStateRecord,
    options: RoachTailStateSanitizeOptions = {}
  ): RoachTailStateRecord {
    const pairingPayload =
      options.hideJoinCode || !state.joinCode ? null : this.buildRoachTailPairingPayload(state)

    return {
      ...state,
      advertisedUrl: this.sanitizeUserFacingUrl(state.advertisedUrl, 38111),
      runtimeOrigin: this.sanitizeUserFacingUrl(
        state.runtimeOrigin,
        process.env.PORT?.trim() || '8080'
      ),
      runtimeTunnelUrl: this.sanitizeUserFacingUrl(
        state.runtimeTunnelUrl ?? state.advertisedUrl,
        38111
      ),
      joinCode: options.hideJoinCode ? null : state.joinCode ?? null,
      joinCodeIssuedAt: options.hideJoinCode ? null : state.joinCodeIssuedAt ?? null,
      joinCodeExpiresAt: options.hideJoinCode ? null : state.joinCodeExpiresAt ?? null,
      pairingPayload,
      pairingIssuedAt: options.hideJoinCode ? null : state.pairingIssuedAt ?? state.joinCodeIssuedAt ?? null,
      peers: state.peers.map((peer) => ({
        id: peer.id,
        name: peer.name,
        platform: peer.platform,
        status: peer.status,
        endpoint: this.sanitizePeerEndpoint(peer.endpoint),
        lastSeenAt: peer.lastSeenAt ?? null,
        allowsExitNode: peer.allowsExitNode ?? false,
        tags: peer.tags ?? [],
      })),
    }
  }

  private async mutateRoachTailState(
    action: NonNullable<RoachTailActionInput['action']>,
    payload: RoachTailActionInput
  ): Promise<RoachTailStateRecord> {
    const statePath = this.roachTailStatePath()
    if (!statePath) {
      throw new Error('RoachTail cannot persist state until the contained RoachNet storage lane exists.')
    }

    const roachTailDir = path.dirname(statePath)
    await mkdir(roachTailDir, { recursive: true })

    const current = await this.readRoachTailStateRaw()
    const next: InternalRoachTailStateRecord = {
      ...current,
      notes: [...current.notes],
      peers: current.peers.map((peer) => ({ ...peer })),
      lastUpdatedAt: new Date().toISOString(),
    }

    switch (action) {
      case 'enable':
        {
          const joinCodeBundle = this.issueRoachTailJoinCode()
          next.joinCode = joinCodeBundle.joinCode
          next.joinCodeIssuedAt = joinCodeBundle.issuedAt
          next.joinCodeExpiresAt = joinCodeBundle.expiresAt
          next.pairingIssuedAt = joinCodeBundle.issuedAt
        }
        next.enabled = true
        next.status = next.peers.length > 0 ? 'connected' : 'armed'
        next.transportMode = next.relayHost ? 'tailnet-relay' : 'local-bridge'
        next.secureOverlay = Boolean(next.relayHost)
        next.advertisedUrl = this.buildRoachTailAdvertisedURL(next.relayHost, this.companionBridgeURL())
        next.runtimeOrigin = this.localBaseUrl().toString()
        next.runtimeTunnelUrl = this.buildRoachTailRuntimeURL(next.relayHost, next.advertisedUrl)
        next.notes = [
          'RoachTail is armed and ready to pair new devices.',
          'Use the join code or QR payload from the desktop to register a private control peer.',
          next.secureOverlay
            ? 'The advertised bridge is already pinned to the secure RoachTail relay host.'
            : 'Add a relay host when you want the private bridge to stop advertising the raw machine address.',
        ]
        break
      case 'disable':
        next.enabled = false
        next.status = 'local-only'
        next.joinCode = null
        next.joinCodeIssuedAt = null
        next.joinCodeExpiresAt = null
        next.pairingPayload = null
        next.pairingIssuedAt = null
        next.notes = [
          'RoachTail is disabled and the desktop has fallen back to the local-only companion lane.',
          'Existing peer records are kept so you can re-arm the mesh without rebuilding every device link.',
        ]
        break
      case 'refresh-join-code':
        {
          const joinCodeBundle = this.issueRoachTailJoinCode()
          next.joinCode = joinCodeBundle.joinCode
          next.joinCodeIssuedAt = joinCodeBundle.issuedAt
          next.joinCodeExpiresAt = joinCodeBundle.expiresAt
          next.pairingIssuedAt = joinCodeBundle.issuedAt
        }
        next.enabled = true
        next.status = next.peers.length > 0 ? 'connected' : 'armed'
        next.transportMode = next.relayHost ? 'tailnet-relay' : 'local-bridge'
        next.secureOverlay = Boolean(next.relayHost)
        next.advertisedUrl = this.buildRoachTailAdvertisedURL(next.relayHost, this.companionBridgeURL())
        next.runtimeOrigin = this.localBaseUrl().toString()
        next.runtimeTunnelUrl = this.buildRoachTailRuntimeURL(next.relayHost, next.advertisedUrl)
        next.notes = [
          'RoachTail issued a fresh join code for the next device pair.',
          'Share the new code or QR payload only with devices you want on the private control lane.',
        ]
        break
      case 'clear-peers':
        next.peers = []
        next.status = next.enabled ? 'armed' : 'local-only'
        next.notes = [
          'RoachTail peer records were cleared from the contained state lane.',
          'You can register the phone, tablet, and desktop again from a clean private-mesh slate.',
        ]
        break
      case 'set-relay-host':
        next.relayHost = payload.relayHost?.trim() || null
        next.transportMode = next.relayHost ? 'tailnet-relay' : 'local-bridge'
        next.secureOverlay = Boolean(next.relayHost)
        next.advertisedUrl = this.buildRoachTailAdvertisedURL(next.relayHost, this.companionBridgeURL())
        next.runtimeOrigin = this.localBaseUrl().toString()
        next.runtimeTunnelUrl = this.buildRoachTailRuntimeURL(next.relayHost, next.advertisedUrl)
        next.notes = [
          next.relayHost
            ? `RoachTail will advertise the relay host ${next.relayHost}.`
            : 'RoachTail relay host was cleared and will fall back to the advertised desktop bridge.',
        ]
        break
      case 'register-peer': {
        const peerId = payload.peerId?.trim() || `peer-${randomUUID().slice(0, 8)}`
        const peerName = payload.peerName?.trim() || 'Linked device'
        const platform = payload.platform?.trim() || 'device'
        const endpoint = payload.endpoint?.trim() || null
        const tags = Array.isArray(payload.tags)
          ? payload.tags.map((tag) => String(tag)).filter(Boolean)
          : []
        const existingIndex = next.peers.findIndex((peer) => peer.id === peerId)
        const peerRecord: InternalRoachTailPeerRecord = {
          id: peerId,
          name: peerName,
          platform,
          status: 'linked',
          endpoint,
          lastSeenAt: new Date().toISOString(),
          allowsExitNode: Boolean(payload.allowsExitNode),
          tags,
        }
        if (existingIndex >= 0) {
          next.peers[existingIndex] = peerRecord
        } else {
          next.peers.unshift(peerRecord)
        }
        next.enabled = true
        next.status = 'connected'
        next.transportMode = next.relayHost ? 'tailnet-relay' : 'local-bridge'
        next.secureOverlay = Boolean(next.relayHost)
        next.advertisedUrl = this.buildRoachTailAdvertisedURL(next.relayHost, this.companionBridgeURL())
        next.runtimeOrigin = this.localBaseUrl().toString()
        next.runtimeTunnelUrl = this.buildRoachTailRuntimeURL(next.relayHost, next.advertisedUrl)
        if (!next.joinCode || !this.isRoachTailJoinCodeFresh(next)) {
          const joinCodeBundle = this.issueRoachTailJoinCode()
          next.joinCode = joinCodeBundle.joinCode
          next.joinCodeIssuedAt = joinCodeBundle.issuedAt
          next.joinCodeExpiresAt = joinCodeBundle.expiresAt
          next.pairingIssuedAt = joinCodeBundle.issuedAt
        }
        next.notes = [
          `${peerName} joined the RoachTail control lane.`,
          'RoachTail can now route remote chat carryover, runtime toggles, and App installs to this desktop.',
        ]
        break
      }
      case 'remove-peer': {
        const peerId = payload.peerId?.trim()
        if (!peerId) {
          throw new Error('A peerId is required to remove a RoachTail peer.')
        }
        next.peers = next.peers.filter((peer) => peer.id !== peerId)
        next.status = next.enabled ? (next.peers.length > 0 ? 'connected' : 'armed') : 'local-only'
        next.notes = [
          'RoachTail removed one peer from the private device lane.',
          next.peers.length > 0
            ? 'Other linked devices remain available on the overlay.'
            : 'No linked peers remain. Refresh the join code when you are ready to add another device.',
        ]
        break
      }
    }

    await writeFile(statePath, JSON.stringify(next, null, 2), 'utf8')
    return this.sanitizeRoachTailState(next)
  }

  private async pairRoachTailPeer(
    joinCode: string,
    payload: RoachTailPairInput
  ) {
    const statePath = this.roachTailStatePath()
    if (!statePath) {
      throw new Error('RoachTail cannot pair devices until the contained RoachNet storage lane exists.')
    }

    const roachTailDir = path.dirname(statePath)
    await mkdir(roachTailDir, { recursive: true })

    const next = await this.readRoachTailStateRaw()
    if (!next.enabled) {
      throw new Error('RoachTail is off on this desktop. Turn it on before pairing a device.')
    }

    if (!this.isRoachTailJoinCodeFresh(next)) {
      throw new Error('That RoachTail join code expired. Refresh the code on the desktop and try again.')
    }

    if (!next.joinCode || next.joinCode.trim().toUpperCase() != joinCode) {
      throw new Error('That RoachTail join code does not match this desktop.')
    }

    const peerId = payload.peerId?.trim() || `peer-${randomUUID().slice(0, 8)}`
    const peerName = payload.peerName?.trim() || 'Linked device'
    const platform = payload.platform?.trim() || 'device'
    const endpoint = payload.endpoint?.trim() || null
    const tags = Array.isArray(payload.tags)
      ? payload.tags.map((tag) => String(tag)).filter(Boolean)
      : []
    const pairToken = this.generateRoachTailPeerToken()
    const tokenHash = this.hashRoachTailToken(pairToken)
    const existingIndex = next.peers.findIndex((peer) => peer.id === peerId)
    const peerRecord: InternalRoachTailPeerRecord = {
      id: peerId,
      name: peerName,
      platform,
      status: 'paired',
      endpoint,
      lastSeenAt: new Date().toISOString(),
      allowsExitNode: Boolean(payload.allowsExitNode),
      tags,
      tokenHash,
      pairedAt: new Date().toISOString(),
      appVersion: payload.appVersion?.trim() || null,
    }

    if (existingIndex >= 0) {
      next.peers[existingIndex] = peerRecord
    } else {
      next.peers.unshift(peerRecord)
    }

    next.status = 'connected'
    next.transportMode = next.relayHost ? 'tailnet-relay' : 'local-bridge'
    next.secureOverlay = Boolean(next.relayHost)
    next.advertisedUrl = this.buildRoachTailAdvertisedURL(next.relayHost, this.companionBridgeURL())
    next.runtimeOrigin = this.localBaseUrl().toString()
    next.runtimeTunnelUrl = this.buildRoachTailRuntimeURL(next.relayHost, next.advertisedUrl)
    next.lastUpdatedAt = new Date().toISOString()
    next.notes = [
      `${peerName} paired over RoachTail.`,
      'This device now has its own private bridge token for chat carryover, runtime control, and App installs.',
      'Refresh the join code if you want to lock the pairing lane back down for the next device.',
    ]

    await writeFile(statePath, JSON.stringify(next, null, 2), 'utf8')

    return {
      success: true,
      message: `${peerName} paired with RoachTail.`,
      token: pairToken,
      peerId,
      bridgeUrl: this.buildRoachTailAdvertisedURL(next.relayHost, this.companionBridgeURL()),
      state: this.sanitizeRoachTailState(next),
    }
  }

  private generateRoachTailJoinCode() {
    const token = randomUUID().replaceAll('-', '').slice(0, 10).toUpperCase()
    return `ROACH-${token.slice(0, 5)}-${token.slice(5)}`
  }

  private issueRoachTailJoinCode() {
    const issuedAt = new Date().toISOString()
    return {
      joinCode: this.generateRoachTailJoinCode(),
      issuedAt,
      expiresAt: new Date(Date.now() + ROACHTAIL_JOIN_CODE_TTL_MS).toISOString(),
    }
  }

  private buildRoachTailAdvertisedURL(relayHost?: string | null, fallbackUrl?: string | null) {
    const trimmedRelay = relayHost?.trim()
    if (trimmedRelay) {
      if (/^https?:\/\//i.test(trimmedRelay)) {
        return trimmedRelay
      }
      return `https://${trimmedRelay}`
    }

    return fallbackUrl?.trim() || null
  }

  private buildRoachTailRuntimeURL(relayHost?: string | null, fallbackUrl?: string | null) {
    return this.buildRoachTailAdvertisedURL(relayHost, fallbackUrl)
  }

  private buildRoachTailPairingPayload(state: InternalRoachTailStateRecord) {
    if (!state.joinCode) {
      return null
    }

    const bridgeUrl = this.sanitizeUserFacingUrl(
      state.advertisedUrl ?? this.companionBridgeURL(),
      38111
    )
    const runtimeOrigin = this.sanitizeUserFacingUrl(
      state.runtimeOrigin ?? this.localBaseUrl().toString(),
      process.env.PORT?.trim() || '8080'
    )
    const runtimeTunnelUrl = this.sanitizeUserFacingUrl(
      state.runtimeTunnelUrl ?? state.advertisedUrl ?? this.companionBridgeURL(),
      38111
    )

    return JSON.stringify({
      schema: 'roachnet.roachtail.v1',
      version: 1,
      networkName: state.networkName,
      deviceName: state.deviceName,
      deviceId: state.deviceId,
      joinCode: state.joinCode,
      joinCodeExpiresAt: state.joinCodeExpiresAt ?? null,
      bridgeUrl,
      runtimeOrigin,
      runtimeTunnelUrl,
      transportMode: state.transportMode,
      secureOverlay: state.secureOverlay,
    })
  }

  private isRoachTailJoinCodeFresh(state: InternalRoachTailStateRecord) {
    if (!state.joinCode) {
      return false
    }

    const expiresAt = state.joinCodeExpiresAt
    if (!expiresAt) {
      return true
    }

    const expiresAtValue = Date.parse(expiresAt)
    if (Number.isNaN(expiresAtValue)) {
      return true
    }

    return expiresAtValue > Date.now()
  }

  private generateRoachTailPeerToken() {
    return `rtp_${randomBytes(24).toString('hex')}`
  }

  private hashRoachTailToken(value: string) {
    return createHash('sha256').update(value).digest('hex')
  }

  private roachTailStatePath() {
    const storagePath = this.storagePath()
    return storagePath ? path.join(storagePath, 'vault', 'roachtail', 'state.json') : null
  }

  private async readRoachSyncState(): Promise<RoachSyncStateRecord> {
    const storagePath = this.storagePath()
    const folderPath = storagePath ? path.join(storagePath, 'vault') : path.join(os.homedir(), 'RoachNet', 'vault')
    const statePath = storagePath ? path.join(storagePath, 'vault', 'roachsync', 'state.json') : null
    const fallback: RoachSyncStateRecord = {
      enabled: false,
      provider: 'Syncthing',
      networkName: 'RoachSync',
      deviceName:
        process.env.ROACHSYNC_DEVICE_NAME?.trim() ||
        process.env.ROACHNET_DEVICE_NAME?.trim() ||
        'RoachNet desktop',
      deviceId: process.env.ROACHSYNC_DEVICE_ID?.trim() || `rs-${randomUUID().slice(0, 8)}`,
      status: 'idle',
      folderId: 'roachnet-vault',
      folderPath,
      guiUrl: this.sanitizeUserFacingUrl(this.publicLoopbackUrl(8384), 8384),
      apiUrl: this.sanitizeUserFacingUrl(this.publicLoopbackUrl(8384, '/rest'), 8384),
      transportMode: process.env.ROACHTAIL_RELAY_HOST?.trim() ? 'tailnet-relay' : 'local-bridge',
      secureOverlay: Boolean(process.env.ROACHTAIL_RELAY_HOST?.trim()),
      notes: [
        'RoachSync is the Syncthing-backed lane for vault sync, settings carryover, and future shared install state.',
        'The contained sync folder points at the RoachNet vault so app data stays grouped instead of leaking across the host.',
      ],
      peers: [],
      lastUpdatedAt: new Date().toISOString(),
    }

    if (!statePath) {
      return fallback
    }

    try {
      const raw = await readFile(statePath, 'utf8')
      const parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== 'object') {
        return fallback
      }

      return {
        enabled: typeof parsed.enabled === 'boolean' ? parsed.enabled : fallback.enabled,
        provider: typeof parsed.provider === 'string' ? parsed.provider : fallback.provider,
        networkName: typeof parsed.networkName === 'string' ? parsed.networkName : fallback.networkName,
        deviceName: typeof parsed.deviceName === 'string' ? parsed.deviceName : fallback.deviceName,
        deviceId: typeof parsed.deviceId === 'string' ? parsed.deviceId : fallback.deviceId,
        status: typeof parsed.status === 'string' ? parsed.status : fallback.status,
        folderId: typeof parsed.folderId === 'string' ? parsed.folderId : fallback.folderId,
        folderPath: typeof parsed.folderPath === 'string' ? parsed.folderPath : fallback.folderPath,
        guiUrl: this.sanitizeUserFacingUrl(
          typeof parsed.guiUrl === 'string' ? parsed.guiUrl : fallback.guiUrl,
          8384
        ),
        apiUrl: this.sanitizeUserFacingUrl(
          typeof parsed.apiUrl === 'string' ? parsed.apiUrl : fallback.apiUrl,
          8384
        ),
        transportMode:
          typeof parsed.transportMode === 'string' ? parsed.transportMode : fallback.transportMode,
        secureOverlay:
          typeof parsed.secureOverlay === 'boolean' ? parsed.secureOverlay : fallback.secureOverlay,
        notes: Array.isArray(parsed.notes)
          ? parsed.notes.filter((value: unknown) => typeof value === 'string')
          : fallback.notes,
        peers: Array.isArray(parsed.peers)
          ? parsed.peers
              .filter((value: unknown) => value && typeof value === 'object')
              .map((peer: Record<string, unknown>, index: number) => ({
                id: typeof peer.id === 'string' ? peer.id : `roachsync-peer-${index}`,
                name: typeof peer.name === 'string' ? peer.name : `RoachSync peer ${index + 1}`,
                deviceId: typeof peer.deviceId === 'string' ? peer.deviceId : `peer-${index}`,
                status: typeof peer.status === 'string' ? peer.status : 'linked',
                lastSeenAt: typeof peer.lastSeenAt === 'string' ? peer.lastSeenAt : null,
              }))
          : fallback.peers,
        lastUpdatedAt:
          typeof parsed.lastUpdatedAt === 'string' ? parsed.lastUpdatedAt : fallback.lastUpdatedAt,
      }
    } catch {
      return fallback
    }
  }

  private async mutateRoachSyncState(
    action: NonNullable<RoachSyncActionInput['action']>,
    payload: RoachSyncActionInput
  ): Promise<RoachSyncStateRecord> {
    const storagePath = this.storagePath()
    if (!storagePath) {
      throw new Error('RoachSync cannot persist state until the contained RoachNet storage lane exists.')
    }

    const statePath = path.join(storagePath, 'vault', 'roachsync', 'state.json')
    await mkdir(path.dirname(statePath), { recursive: true })

    const current = await this.readRoachSyncState()
    const next: RoachSyncStateRecord = {
      ...current,
      transportMode: process.env.ROACHTAIL_RELAY_HOST?.trim() ? 'tailnet-relay' : 'local-bridge',
      secureOverlay: Boolean(process.env.ROACHTAIL_RELAY_HOST?.trim()),
      lastUpdatedAt: new Date().toISOString(),
      peers: current.peers.map((peer) => ({ ...peer })),
      notes: [...current.notes],
    }

    switch (action) {
      case 'enable':
        next.enabled = true
        next.status = next.peers.length > 0 ? 'syncing' : 'armed'
        next.notes = [
          'RoachSync is armed and ready to keep the RoachNet vault moving between devices.',
          'Syncthing will keep the contained vault path as the sync root instead of spilling state across the host.',
        ]
        break
      case 'disable':
        next.enabled = false
        next.status = 'idle'
        next.notes = [
          'RoachSync is disabled and the vault stays local to this machine.',
          'Existing peer records stay on disk so you can re-arm the sync lane later.',
        ]
        break
      case 'refresh':
        next.status = next.enabled ? (next.peers.length > 0 ? 'syncing' : 'armed') : 'idle'
        next.notes = [
          'RoachSync refreshed its contained state.',
          'Use this after changing relay or folder settings to keep the sync lane aligned.',
        ]
        break
      case 'set-folder-path':
        next.folderPath = payload.folderPath?.trim() || next.folderPath
        next.notes = [
          `RoachSync now points at ${next.folderPath}.`,
          'Keep this inside the contained RoachNet storage lane when you want backups and resets to stay one-shot.',
        ]
        break
      case 'clear-peers':
        next.peers = []
        next.status = next.enabled ? 'armed' : 'idle'
        next.notes = [
          'RoachSync peer records were cleared.',
          'Add devices again from a clean sync slate when you are ready.',
        ]
        break
    }

    await writeFile(statePath, JSON.stringify(next, null, 2), 'utf8')
    return next
  }

  private companionBridgeURL() {
    const advertised = process.env.ROACHNET_COMPANION_ADVERTISED_URL?.trim()
    if (advertised) {
      return this.sanitizeUserFacingUrl(advertised, process.env.ROACHNET_COMPANION_PORT?.trim() || '38111')
    }

    const configuredPort = process.env.ROACHNET_COMPANION_PORT?.trim() || '38111'
    return this.sanitizeUserFacingUrl(this.publicLoopbackUrl(configuredPort), configuredPort)
  }

  private storagePath() {
    return process.env.ROACHNET_STORAGE_PATH?.trim() || process.env.ROACHNET_HOST_STORAGE_PATH?.trim()
  }

  private isPeerRoachTailRequest(request?: HttpContext['request']) {
    return request?.header('x-roachtail-auth-kind')?.trim().toLowerCase() === 'peer'
  }

  private roachTailPeerID(request?: HttpContext['request']) {
    return request?.header('x-roachtail-peer-id')?.trim() || null
  }

  private syntheticSession(title: string, model?: string, existingId?: string) {
    return {
      id: existingId?.startsWith('local-') ? existingId : `local-${randomUUID()}`,
      title,
      model: model || null,
      timestamp: new Date().toISOString(),
    }
  }

  private syntheticMessage(role: 'user' | 'assistant', content: string) {
    return {
      id: `local-message-${randomUUID()}`,
      role,
      content,
      createdAt: new Date().toISOString(),
    }
  }
}
