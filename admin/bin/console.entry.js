import 'reflect-metadata'
import { Ignitor } from '@adonisjs/core'

function bootDebug(stage, details) {
  if (process.env.ROACHNET_DEBUG_BOOT !== '1') {
    return
  }

  console.log(`[roachnet:ace] ${stage}`, details ?? {})
}

async function prettyPrintBootError(error) {
  if (error instanceof Error) {
    console.error(error.stack ?? error.message)
    return
  }

  console.error(error)
}

const APP_ROOT = new URL('../', import.meta.url)

const IMPORTER = (filePath) => {
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

ignitor.tap((app) => {
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
