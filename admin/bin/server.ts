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
import { appendFileSync } from 'node:fs'
import 'reflect-metadata'
import { Ignitor } from '@adonisjs/core'
const bootTraceStartedAt = Date.now()

function writeBootTrace(stage: string, details?: Record<string, unknown>) {
  const outputPath = process.env.ROACHNET_BOOT_TRACE_FILE
  if (!outputPath) {
    return
  }

  const elapsedMs = Date.now() - bootTraceStartedAt
  const payload = details ? ` ${JSON.stringify(details)}` : ''
  appendFileSync(outputPath, `[roachnet:bootfile +${elapsedMs}ms] ${stage}${payload}\n`, 'utf8')
}

function bootDebug(stage: string, details?: Record<string, unknown>) {
  writeBootTrace(stage, details)

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

writeBootTrace('module:loaded', {
  appRoot: APP_ROOT.href,
  cwd: process.cwd(),
  nodeEnv: process.env.NODE_ENV,
})

bootDebug('bootstrap:start', {
  appRoot: APP_ROOT.href,
  cwd: process.cwd(),
  nodeEnv: process.env.NODE_ENV,
})

const ignitor = new Ignitor(APP_ROOT, { importer: IMPORTER })

ignitor
  .tap((app: any) => {
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
      if (process.env.ROACHNET_RECONCILE_ON_STARTUP === '0') {
        bootDebug('app:ready:manifests-skipped')
        return
      }

      setTimeout(() => {
        void (async () => {
          try {
            const collectionManifestService = new (await import('#services/collection_manifest_service')).CollectionManifestService()
            await collectionManifestService.reconcileFromFilesystem()
            bootDebug('app:ready:manifests-reconciled')
          } catch (error) {
            // Catch and log any errors during reconciliation to prevent the server from crashing
            console.error('Error during collection manifest reconciliation:', error)
          }
        })()
      }, 0)
    })
  })
async function startHttpServer() {
  await ignitor.httpServer().start((handler) => {
    bootDebug('node:http:create:start')
    return createServer(handler)
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
