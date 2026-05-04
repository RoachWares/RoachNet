import KVStore from '#models/kv_store'
import { AIRuntimeService } from '#services/ai_runtime_service'
import { BenchmarkService } from '#services/benchmark_service'
import { MapService } from '#services/map_service'
import { OllamaService } from '#services/ollama_service'
import { SystemService } from '#services/system_service'
import { updateSettingSchema } from '#validators/settings'
import { inject } from '@adonisjs/core'
import logger from '@adonisjs/core/services/logger'
import type { HttpContext } from '@adonisjs/core/http'
import type { KVStoreKey } from '../../types/kv_store.js'

@inject()
export default class SettingsController {
  constructor(
    private systemService: SystemService,
    private mapService: MapService,
    private benchmarkService: BenchmarkService,
    private ollamaService: OllamaService,
    private aiRuntimeService: AIRuntimeService
  ) {}

  private canRenderInertia(inertia: HttpContext['inertia'] | undefined) {
    return Boolean(inertia && typeof inertia.render === 'function')
  }

  private escapeHtml(value: string) {
    return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
  }

  private renderFallbackPage(
    response: HttpContext['response'],
    {
      title,
      summary,
      badge,
      sections,
      actions = [],
    }: {
      title: string
      summary: string
      badge: string
      sections: Array<{ title: string; items: string[] }>
      actions?: Array<{ label: string; href: string }>
    }
  ) {
    const sectionMarkup = sections
      .map((section) => {
        const itemsMarkup = section.items.length
          ? section.items.map((item) => `<li>${this.escapeHtml(item)}</li>`).join('')
          : '<li>No data yet.</li>'

        return `<section><h2>${this.escapeHtml(section.title)}</h2><ul>${itemsMarkup}</ul></section>`
      })
      .join('')

    const actionsMarkup = actions.length
      ? `<nav class="actions" aria-label="${this.escapeHtml(title)} actions">${actions
          .map(
            (action) =>
              `<a class="action" href="${this.escapeHtml(action.href)}">${this.escapeHtml(action.label)}</a>`
          )
          .join('')}</nav>`
      : ''

    return response
      .status(200)
      .header('content-type', 'text/html; charset=utf-8')
      .send(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${this.escapeHtml(title)}</title>
    <style>
      :root { color-scheme: dark; }
      body {
        margin: 0;
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
        background: radial-gradient(circle at top, #101b2b 0%, #0a1018 58%, #04070c 100%);
        color: #eef3f8;
      }
      main {
        max-width: 860px;
        margin: 0 auto;
        padding: 56px 24px 72px;
      }
      h1 { font-size: 36px; line-height: 1.05; margin: 0 0 14px; }
      h2 {
        margin: 0 0 12px;
        font-size: 14px;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        color: #79ebc9;
      }
      p {
        margin: 0;
        color: rgba(238,243,248,0.78);
        font-size: 15px;
        line-height: 1.65;
      }
      ul { margin: 0; padding-left: 18px; color: rgba(238,243,248,0.9); }
      li { margin: 8px 0; line-height: 1.45; }
      .chip {
        display: inline-block;
        margin: 18px 0 24px;
        padding: 10px 14px;
        border-radius: 999px;
        background: rgba(122, 240, 199, 0.12);
        color: #7af0c7;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 12px;
      }
      section {
        margin-top: 22px;
        padding: 18px 20px;
        border-radius: 18px;
        border: 1px solid rgba(122, 240, 199, 0.14);
        background: rgba(10, 18, 28, 0.78);
        box-shadow: inset 0 1px 0 rgba(255,255,255,0.03);
      }
      .actions {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        margin: 0 0 26px;
      }
      .action {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 12px 16px;
        border-radius: 999px;
        border: 1px solid rgba(122, 240, 199, 0.16);
        background: rgba(122, 240, 199, 0.08);
        color: #eef3f8;
        text-decoration: none;
        font-size: 13px;
        font-weight: 700;
        letter-spacing: 0.01em;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>${this.escapeHtml(title)}</h1>
      <p>${this.escapeHtml(summary)}</p>
      <div class="chip">${this.escapeHtml(badge)}</div>
      ${actionsMarkup}
      ${sectionMarkup}
    </main>
  </body>
</html>`)
  }

  async system({ inertia, response }: HttpContext) {
    const systemInfo = await this.systemService.getSystemInfo()

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/system', {
        system: {
          info: systemInfo,
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'System',
      summary:
        'RoachNet is running in native mode. This fallback page keeps system details reachable when the old web shell is unavailable.',
      badge: `${systemInfo.hardwareProfile.platformLabel} · ${systemInfo.hardwareProfile.recommendedModelClass}`,
      sections: [
        {
          title: 'Machine',
          items: [
            `${systemInfo.cpu.brand ?? 'CPU'} · ${systemInfo.mem.total} bytes memory`,
            `Recommended runtime: ${systemInfo.hardwareProfile.recommendedRuntime}`,
          ],
        },
      ],
    })
  }

  async apps({ inertia, response }: HttpContext) {
    const services = await this.systemService.getServices({ installedOnly: false })

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/apps', {
        system: {
          services,
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'Apps',
      summary: 'Managed services are still available even when the legacy settings shell is absent.',
      badge: `${services.filter((service) => service.installed).length} installed`,
      sections: [
        {
          title: 'Services',
          items: services.map(
            (service) => `${service.friendly_name ?? service.service_name} · ${service.status ?? 'unknown'}`
          ),
        },
      ],
    })
  }

  async ai({ inertia, response }: HttpContext) {
    const [systemInfo, providers] = await Promise.all([
      this.systemService.getSystemInfo(),
      this.aiRuntimeService.getProviders(),
    ])

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/ai', {
        system: {
          info: systemInfo,
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'AI Control',
      summary:
        'RoachNet now treats the native shell as the main control surface. This fallback keeps the contained AI lane visible when the legacy settings shell is missing.',
      badge: `${systemInfo.hardwareProfile.platformLabel} · ${systemInfo.hardwareProfile.recommendedModelClass}`,
      actions: [
        { label: 'Open Model Store', href: '/settings/models' },
        { label: 'Back to Home', href: '/home' },
      ],
      sections: [
        {
          title: 'Contained Providers',
          items: Object.entries(providers.providers).map(([name, provider]) => {
            const target = provider.baseUrl ? ` · ${provider.baseUrl}` : ''
            return `${name} · ${provider.available ? 'ready' : 'offline'}${target}`
          }),
        },
        {
          title: 'Lane Policy',
          items: [
            'Local lane · preferred for privacy, portability, and predictable first-launch behavior.',
            'Cloud lane · optional fast-start path when the user adds a remote provider through the native secrets surface.',
          ],
        },
      ],
    })
  }

  async legal({ inertia, response }: HttpContext) {
    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/legal', {})
    }

    return this.renderFallbackPage(response, {
      title: 'Legal',
      summary:
        'The legal surface is still available while the legacy settings web shell is being retired.',
      badge: 'native fallback',
      sections: [],
    })
  }

  async support({ inertia, response }: HttpContext) {
    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/support', {})
    }

    return this.renderFallbackPage(response, {
      title: 'Support',
      summary: 'RoachNet support and diagnostics remain reachable from the native lane.',
      badge: 'native fallback',
      sections: [],
    })
  }

  async maps({ inertia, response }: HttpContext) {
    const baseAssetsCheck = await this.mapService.ensureBaseAssets()
    const regionFiles = await this.mapService.listRegions()

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/maps', {
        maps: {
          baseAssetsExist: baseAssetsCheck,
          regionFiles: regionFiles.files,
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'Maps',
      summary:
        'RoachNet keeps the native map workflow online even if the older settings shell is unavailable.',
      badge: baseAssetsCheck ? 'base assets ready' : 'base assets missing',
      sections: [
        {
          title: 'Installed Regions',
          items: regionFiles.files.map((file) => file.name),
        },
      ],
    })
  }

  async models({ inertia, response }: HttpContext) {
    const [availableModels, runtimeStatus, chatSuggestionsEnabled, aiAssistantCustomName] =
      await Promise.all([
        this.ollamaService.getAvailableModels({
          sort: 'pulls',
          recommendedOnly: false,
          query: null,
          limit: 15,
        }),
        this.aiRuntimeService.getProvider('ollama'),
        KVStore.getValue('chat.suggestionsEnabled'),
        KVStore.getValue('ai.assistantCustomName'),
      ])

    let installedModels: Awaited<ReturnType<OllamaService['getModels']>> = []
    if (runtimeStatus.available) {
      try {
        installedModels = await this.ollamaService.getModels()
      } catch (error) {
        logger.warn(
          `[SettingsController] Failed to fetch installed Ollama models: ${error instanceof Error ? error.message : error}`
        )
      }
    }

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/models', {
        models: {
          availableModels: availableModels?.models || [],
          installedModels: installedModels || [],
          runtimeStatus,
          settings: {
            chatSuggestionsEnabled: chatSuggestionsEnabled ?? false,
            aiAssistantCustomName: aiAssistantCustomName ?? '',
          },
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'Model Store',
      summary:
        'The contained Ollama lane is active. This fallback page keeps the revived model store reachable from the native shell while the old Inertia settings view is phased out.',
      badge: runtimeStatus.available
        ? `contained lane · ${runtimeStatus.baseUrl ?? 'connected'}`
        : runtimeStatus.error ?? 'ollama offline',
      actions: [
        { label: 'Open AI Control', href: '/settings/ai' },
        { label: 'Back to Home', href: '/home' },
      ],
      sections: [
        {
          title: 'Installed Models',
          items: (installedModels || []).map((model) => model.name),
        },
        {
          title: 'Recommended Models',
          items: (availableModels?.models || []).slice(0, 8).flatMap((model) =>
            model.tags.slice(0, 1).map((tag) => `${model.name} · ${tag.name} · ${tag.size}`)
          ),
        },
        {
          title: 'Cloud Lane',
          items: [
            'Fast first boot stays available when the user adds a remote provider in the native secrets surface.',
            'RoachClaw can keep the contained local lane as the default while still falling back to a cloud lane when local models are cold.',
          ],
        },
        {
          title: 'Controls',
          items: [
            `Chat suggestions: ${chatSuggestionsEnabled ?? false ? 'enabled' : 'disabled'}`,
            `Assistant name: ${aiAssistantCustomName?.toString() || 'default'}`,
          ],
        },
      ],
    })
  }

  async update({ inertia, response }: HttpContext) {
    const [updateInfo, earlyAccess] = await Promise.all([
      this.systemService.checkLatestVersion(),
      KVStore.getValue('system.earlyAccess'),
    ])

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/update', {
        system: {
          updateAvailable: updateInfo.updateAvailable,
          latestVersion: updateInfo.latestVersion,
          currentVersion: updateInfo.currentVersion,
          earlyAccess: earlyAccess ?? false,
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'Updates',
      summary:
        'RoachNet update state is still reachable in native mode without the old settings shell.',
      badge: updateInfo.updateAvailable
        ? `update available · ${updateInfo.latestVersion}`
        : `current · ${updateInfo.currentVersion}`,
      sections: [
        {
          title: 'Release Channel',
          items: [
            `Early access: ${earlyAccess ?? false ? 'enabled' : 'disabled'}`,
          ],
        },
      ],
    })
  }

  async zim({ inertia, response }: HttpContext) {
    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/zim/index', {})
    }

    return this.renderFallbackPage(response, {
      title: 'Library',
      summary: 'The offline library controls remain reachable from native mode.',
      badge: 'native fallback',
      sections: [],
    })
  }

  async zimRemote({ inertia, response }: HttpContext) {
    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/zim/remote-explorer', {})
    }

    return this.renderFallbackPage(response, {
      title: 'Remote Explorer',
      summary:
        'Remote ZIM exploration remains reachable while the legacy web settings shell is phased out.',
      badge: 'native fallback',
      sections: [],
    })
  }

  async benchmark({ inertia, response }: HttpContext) {
    const latestResult = await this.benchmarkService.getLatestResult()
    const status = this.benchmarkService.getStatus()

    if (this.canRenderInertia(inertia)) {
      return inertia.render('settings/benchmark', {
        benchmark: {
          latestResult,
          status: status.status,
          currentBenchmarkId: status.benchmarkId,
        },
      })
    }

    return this.renderFallbackPage(response, {
      title: 'Benchmark',
      summary: 'RoachNet benchmark state remains reachable from the native shell.',
      badge: `status · ${status.status}`,
      sections: [
        {
          title: 'Latest Result',
          items: latestResult ? [JSON.stringify(latestResult)] : [],
        },
      ],
    })
  }

  async getSetting({ request, response }: HttpContext) {
    const key = request.qs().key
    const value = await KVStore.getValue(key as KVStoreKey)
    return response.status(200).send({ key, value })
  }

  async updateSetting({ request, response }: HttpContext) {
    const reqData = await request.validateUsing(updateSettingSchema)
    await this.systemService.updateSetting(reqData.key, reqData.value)
    return response.status(200).send({ success: true, message: 'Setting updated successfully' })
  }
}
