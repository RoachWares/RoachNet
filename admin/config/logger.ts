import env from '#start/env'
import { defineConfig, targets } from '@adonisjs/core/logger'
import { join } from 'path'
import { fileURLToPath } from 'node:url'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] logger')
}

const isProduction = env.get('NODE_ENV') === 'production'
const defaultStorageRoot = fileURLToPath(new URL('../storage', import.meta.url))
const storageRoot = env.get('ROACHNET_STORAGE_PATH')?.trim() || defaultStorageRoot
const logDestination = join(storageRoot, 'logs', 'admin.log')

const loggerConfig = defineConfig({
  default: 'app',

  /**
   * The loggers object can be used to define multiple loggers.
   * By default, we configure only one logger (named "app").
   */
  loggers: {
    app: {
      enabled: true,
      name: env.get('APP_NAME'),
      level: isProduction ? env.get('LOG_LEVEL') : 'debug',
      transport: {
        targets:
          targets()
            .pushIf(!isProduction, targets.pretty())
            .pushIf(isProduction, targets.file({ destination: logDestination, mkdir: true }))
            .toArray(),
      },
    },
  },
})

export default loggerConfig

/**
 * Inferring types for the list of loggers you have configured
 * in your application.
 */
declare module '@adonisjs/core/types' {
  export interface LoggersList extends InferLoggers<typeof loggerConfig> { }
}
