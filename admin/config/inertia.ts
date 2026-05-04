import { defineConfig } from '@adonisjs/inertia'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] inertia')
}

const inertiaConfig = defineConfig({
  /**
   * Path to the Edge view that will be used as the root view for Inertia responses
   */
  rootView: 'inertia_layout',

  /**
   * Options for the server-side rendering
   */
  ssr: {
    enabled: false,
    entrypoint: 'inertia/app/ssr.tsx'
  }
})

export default inertiaConfig
