/*
|--------------------------------------------------------------------------
| HTTP server entrypoint
|--------------------------------------------------------------------------
|
| The "server.ts" file is the entrypoint for starting the AdonisJS HTTP
| server. Either you can run this file directly or use the "serve"
| command to run this file and monitor file changes
|
*/

import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import 'reflect-metadata'

const require = createRequire(import.meta.url)
const adonisCoreRoot = path.dirname(require.resolve('@adonisjs/core/package.json'))
const ignitorModuleUrl = pathToFileURL(
  path.join(adonisCoreRoot, 'build', 'src', 'ignitor', 'main.js')
).href
const { Ignitor } = await import(ignitorModuleUrl)

function bootDebug(stage: string, details?: Record<string, unknown>) {
  if (process.env.ROACHNET_DEBUG_BOOT !== '1') {
    return
  }

  console.log(`[roachnet:boot] ${stage}`, details ?? {})
}

async function prettyPrintBootError(error: unknown) {
  if (error instanceof Error) {
    console.error(error.stack ?? error.message)
    return
  }

  console.error(error)
}

async function listen(nodeHttpServer: ReturnType<typeof createServer>) {
  const host = process.env.HOST || '0.0.0.0'
  const port = Number(process.env.PORT || '3333')

  await new Promise<void>((resolve, reject) => {
    nodeHttpServer.listen(port, host)
    nodeHttpServer.once('listening', () => resolve())
    nodeHttpServer.once('error', reject)
  })

  return { host, port }
}

/**
 * URL to the application root. AdonisJS need it to resolve
 * paths to file and directories for scaffolding commands
 */
const APP_ROOT = new URL('../', import.meta.url)

/**
 * The importer is used to import files in context of the
 * application.
 */
const IMPORTER = (filePath: string) => {
  bootDebug('importer', { filePath })
  if (filePath.startsWith('./') || filePath.startsWith('../')) {
    return import(new URL(filePath, APP_ROOT).href)
  }
  return import(filePath)
}

bootDebug('bootstrap:start', {
  appRoot: APP_ROOT.href,
  cwd: process.cwd(),
  nodeEnv: process.env.NODE_ENV,
})

const ignitor = new Ignitor(APP_ROOT, { importer: IMPORTER })

ignitor
  .tap((app) => {
    bootDebug('ignitor:tap')
    app.booting(async () => {
      bootDebug('app:booting:start')
      await import('#start/env')
      bootDebug('app:booting:env-ready')
    })
    app.listen('SIGTERM', () => app.terminate())
    app.listenIf(app.managedByPm2, 'SIGINT', () => app.terminate())
    app.ready(async () => {
      bootDebug('app:ready:start')
      try {
        const collectionManifestService = new (await import('#services/collection_manifest_service')).CollectionManifestService()
        await collectionManifestService.reconcileFromFilesystem()
        bootDebug('app:ready:manifests-reconciled')
      } catch (error) {
        // Catch and log any errors during reconciliation to prevent the server from crashing
        console.error('Error during collection manifest reconciliation:', error)
      }
    })
  })
async function startHttpServer() {
  const app = ignitor.createApp('web')
  bootDebug('app:create:done')

  await app.init()
  bootDebug('app:init:done')

  await app.boot()
  bootDebug('app:boot:done')

  await app.start(async () => {
    bootDebug('app:start:callback:start')
    const server = await app.container.make('server')
    bootDebug('container:server:resolved')
    await server.boot()
    bootDebug('server:boot:done')

    const httpServer = createServer(server.handle.bind(server))
    server.setNodeServer(httpServer)
    bootDebug('node:http:create:done')

    const logger = await app.container.make('logger')
    bootDebug('container:logger:resolved')
    const emitter = await app.container.make('emitter')
    bootDebug('container:emitter:resolved')

    const payload = await listen(httpServer)
    bootDebug('http:listen:done', payload)

    app.notify({ isAdonisJS: true, environment: 'web', ...payload })
    logger.info('started HTTP server on %s:%s', payload.host, payload.port)
    emitter.emit('http:server_ready', payload)

    app.terminating(async () => {
      bootDebug('app:terminating')
      await new Promise<void>((resolve) => httpServer.close(() => resolve()))
    })

    httpServer.once('error', (error) => {
      logger.fatal({ err: error }, error.message)
      process.exitCode = 1
      void app.terminate()
    })
  })

  bootDebug('http:start:resolved')
}

void startHttpServer().catch((error) => {
    process.exitCode = 1
    bootDebug('http:start:failed', {
      name: error instanceof Error ? error.name : typeof error,
      message: error instanceof Error ? error.message : String(error),
    })
    void prettyPrintBootError(error)
  })
