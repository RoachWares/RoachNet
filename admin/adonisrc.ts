import { defineConfig } from '@adonisjs/core/app'
import { appendFileSync } from 'node:fs'

const nativeOnly = process.env.ROACHNET_NATIVE_ONLY === '1'
const bootTraceStartedAt = Date.now()

function writeBootTrace(stage: string, details?: Record<string, unknown>) {
  const outputPath = process.env.ROACHNET_BOOT_TRACE_FILE
  if (!outputPath) {
    return
  }

  const elapsedMs = Date.now() - bootTraceStartedAt
  const payload = details ? ` ${JSON.stringify(details)}` : ''
  appendFileSync(outputPath, `[roachnet:adonisrc +${elapsedMs}ms] ${stage}${payload}\n`, 'utf8')
}

function debugImport(filePath: string) {
  writeBootTrace('import', { filePath })

  if (process.env.ROACHNET_DEBUG_BOOT === '1') {
    console.log(`[roachnet:provider] ${filePath}`)
  }

  return import(filePath)
}

writeBootTrace('module:loaded', { nativeOnly })

const config = defineConfig({
  /*
  |--------------------------------------------------------------------------
  | Experimental flags
  |--------------------------------------------------------------------------
  |
  | The following features will be enabled by default in the next major release
  | of AdonisJS. You can opt into them today to avoid any breaking changes
  | during upgrade.
  |
  */
  experimental: {
    mergeMultipartFieldsAndFiles: true,
    shutdownInReverseOrder: true,
  },

  /*
  |--------------------------------------------------------------------------
  | Commands
  |--------------------------------------------------------------------------
  |
  | List of ace commands to register from packages. The application commands
  | will be scanned automatically from the "./commands" directory.
  |
  */
  commands: [() => debugImport('@adonisjs/core/commands'), () => debugImport('@adonisjs/lucid/commands')],

  /*
  |--------------------------------------------------------------------------
  | Service providers
  |--------------------------------------------------------------------------
  |
  | List of service providers to import and register when booting the
  | application
  |
  */
  providers: [
    () => debugImport('@adonisjs/core/providers/app_provider'),
    () => debugImport('@adonisjs/core/providers/hash_provider'),
    {
      file: () => debugImport('@adonisjs/core/providers/repl_provider'),
      environment: ['repl', 'test'],
    },
    () => debugImport('@adonisjs/core/providers/vinejs_provider'),
    ...(nativeOnly ? [] : [() => debugImport('@adonisjs/core/providers/edge_provider')]),
    ...(nativeOnly ? [] : [() => debugImport('@adonisjs/session/session_provider')]),
    ...(nativeOnly ? [] : [() => debugImport('@adonisjs/vite/vite_provider')]),
    ...(nativeOnly ? [] : [() => debugImport('@adonisjs/shield/shield_provider')]),
    ...(nativeOnly ? [] : [() => debugImport('@adonisjs/static/static_provider')]),
    () => debugImport('@adonisjs/cors/cors_provider'),
    () => debugImport('@adonisjs/lucid/database_provider'),
    ...(nativeOnly ? [] : [() => debugImport('@adonisjs/inertia/inertia_provider')]),
    ...(process.env.ROACHNET_DISABLE_TRANSMIT === '1'
      ? []
      : [() => debugImport('@adonisjs/transmit/transmit_provider')]),
    ...(nativeOnly ? [] : [() => debugImport('#providers/map_static_provider')])
  ],

  /*
  |--------------------------------------------------------------------------
  | Preloads
  |--------------------------------------------------------------------------
  |
  | List of modules to import before starting the application.
  |
  */
  preloads: [
    () => debugImport('#start/routes'),
    () => debugImport('#start/kernel'),
  ],

  /*
  |--------------------------------------------------------------------------
  | Tests
  |--------------------------------------------------------------------------
  |
  | List of test suites to organize tests by their type. Feel free to remove
  | and add additional suites.
  |
  */
  tests: {
    suites: [
      {
        files: ['tests/unit/**/*.spec(.ts|.js)'],
        name: 'unit',
        timeout: 2000,
      },
      {
        files: ['tests/functional/**/*.spec(.ts|.js)'],
        name: 'functional',
        timeout: 30000,
      },
    ],
    forceExit: false,
  },

  /*
  |--------------------------------------------------------------------------
  | Metafiles
  |--------------------------------------------------------------------------
  |
  | A collection of files you want to copy to the build folder when creating
  | the production build.
  |
  */
  metaFiles: [
    {
      pattern: 'resources/views/**/*.edge',
      reloadServer: false,
    },
    {
      pattern: 'public/**',
      reloadServer: false,
    },
  ],

  hooks: {
    buildStarting: [() => debugImport('@adonisjs/vite/build_hook')],
  },
})

writeBootTrace('config:defined', { nativeOnly })

export default config
