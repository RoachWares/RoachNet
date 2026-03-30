import { createRequire } from 'node:module'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const require = createRequire(import.meta.url)
const adonisCoreRoot = path.dirname(require.resolve('@adonisjs/core/package.json'))
const ignitorModuleUrl = pathToFileURL(
  path.join(adonisCoreRoot, 'build', 'src', 'ignitor', 'main.js')
).href
const aceKernelModuleUrl = pathToFileURL(
  path.join(adonisCoreRoot, 'build', 'modules', 'ace', 'create_kernel.js')
).href
const { Ignitor } = await import(ignitorModuleUrl)

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

  const app = ignitor.createApp('console')
  bootDebug('app:create:done', { commandName })

  await app.init()
  bootDebug('app:init:done')

  const { createAceKernel } = await import(aceKernelModuleUrl)
  bootDebug('ace:kernel:module:ready')
  const kernel = createAceKernel(app, commandName)
  bootDebug('ace:kernel:created')
  app.container.bindValue('ace', kernel)

  kernel.loading(async (metaData) => {
    bootDebug('ace:kernel:loading', {
      commandName: metaData.commandName,
      startApp: metaData.options.startApp,
    })

    if (metaData.options.startApp && !app.isReady) {
      if (metaData.commandName === 'repl') {
        app.setEnvironment('repl')
      }

      await app.boot()
      bootDebug('app:boot:done')
      await app.start(async () => {})
      bootDebug('app:start:done')
    }
  })

  bootDebug('ace:handle:start', { argv })
  await kernel.handle(argv)
  bootDebug('ace:handle:resolved')

  const mainCommand = kernel.getMainCommand()
  if (!mainCommand || !mainCommand.staysAlive) {
    process.exitCode = kernel.exitCode
    await app.terminate()
    return
  }

  app.terminating(() => {
    process.exitCode = mainCommand.exitCode
  })
}

void bootstrapAce().catch((error) => {
  process.exitCode = 1
  bootDebug('ace:handle:failed', {
    name: error instanceof Error ? error.name : typeof error,
    message: error instanceof Error ? error.message : String(error),
  })
  void prettyPrintBootError(error)
})
