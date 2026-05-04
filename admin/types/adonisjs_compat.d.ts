import '@adonisjs/core/providers/vinejs_provider'

declare module '@adonisjs/inertia/types' {
  interface InertiaPages {
    [page: string]: any
  }

  interface SharedProps {
    appVersion: string
    environment: string
    aiAssistantName: string
  }
}
