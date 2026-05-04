import { defineConfig } from 'vite'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import inertia from '@adonisjs/inertia/vite'
import react from '@vitejs/plugin-react'
import adonisjs from '@adonisjs/vite/client'
import tailwindcss from '@tailwindcss/vite'

const rootDir = dirname(fileURLToPath(import.meta.url))

export default defineConfig(({ mode }) => {
  const isProduction = mode === 'production'

  return {
    plugins: [inertia({ ssr: { enabled: false } }), react(), tailwindcss(), adonisjs({ entrypoints: ['inertia/app/app.tsx'], reload: ['resources/views/**/*.edge'] })],
    define: {
      'process.env.NODE_ENV': JSON.stringify(isProduction ? 'production' : mode),
    },
    esbuild: {
      jsxDev: !isProduction,
    },
    build: {
      rollupOptions: {
        output: {
          manualChunks(id) {
            if (!id.includes('node_modules')) {
              return
            }

            if (id.includes('maplibre-gl')) {
              return 'vendor-maplibre'
            }

            if (id.includes('react-map-gl')) {
              return 'vendor-react-map'
            }

            if (id.includes('pmtiles')) {
              return 'vendor-pmtiles'
            }

            if (id.includes('@tanstack/react-query-devtools')) {
              return 'vendor-devtools'
            }

            if (id.includes('@uppy/')) {
              return 'vendor-uppy'
            }

            if (id.includes('@headlessui/react')) {
              return 'vendor-headlessui'
            }

            if (id.includes('@tanstack/react-query') || id.includes('react-adonis-transmit')) {
              return 'vendor-data'
            }

            if (id.includes('@inertiajs/react')) {
              return 'vendor-inertia'
            }

            if (id.includes('/react-dom/') || id.includes('/react/')) {
              return 'vendor-react'
            }
          },
        },
      },
    },

    /**
     * Define aliases for importing modules from
     * your frontend code
     */
    resolve: {
      alias: {
        '~/': `${rootDir}/inertia/`,
      },
    },
  }
})
