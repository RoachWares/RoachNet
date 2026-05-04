/*
|--------------------------------------------------------------------------
| Ace entry point
|--------------------------------------------------------------------------
|
| The "console.ts" file is the entrypoint for booting the AdonisJS
| command-line framework and executing commands.
|
| Commands do not boot the application, unless the currently running command
| has "options.startApp" flag set to true.
|
*/

import 'reflect-metadata'
import { Ignitor } from '@adonisjs/core'

function bootDebug(stage: string, details?: Record<string, unknown>) {
  if (process.env.ROACHNET_DEBUG_BOOT !== '1') {
    return
  }

  console.log(`[roachnet:ace] ${stage}`, details ?? {})
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

bootDebug('bootstrap:start', {
  appRoot: APP_ROOT.href,
  cwd: process.cwd(),
  argv: process.argv.slice(2),
})

const ignitor = new Ignitor(APP_ROOT, { importer: IMPORTER })

ignitor.tap((app: any) => {
  bootDebug('ignitor:tap')
  app.booting(async () => {
    bootDebug('app:booting:start')
    await import('#start/env')
    bootDebug('app:booting:env-ready')
  })
  app.listen('SIGTERM', () => app.terminate())
  app.listenIf(app.managedByPm2, 'SIGINT', () => app.terminate())
})

async function bootstrapAce() {
  const argv = process.argv.slice(2)
  const commandNameIndex = argv.findIndex((value) => !value.startsWith('-'))
  const commandName = commandNameIndex >= 0 ? argv[commandNameIndex] : undefined

  bootDebug('ace:handle:start', { argv, commandName })
  await ignitor
    .ace()
    .configure(async () => {
      bootDebug('ace:kernel:configured', { commandName })
    })
    .handle(argv)
  bootDebug('ace:handle:resolved')
}

void bootstrapAce().catch((error) => {
  process.exitCode = 1
  bootDebug('ace:handle:failed', {
    name: error instanceof Error ? error.name : typeof error,
    message: error instanceof Error ? error.message : String(error),
  })
  void prettyPrintBootError(error)
})
