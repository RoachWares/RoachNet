/*
|--------------------------------------------------------------------------
| Queue worker entrypoint
|--------------------------------------------------------------------------
|
| Starts BullMQ workers without going through Ace. This is used by the
| standalone/native runtime where the Ace bootstrap can hang before the
| queue workers are started.
|
*/

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

  console.log(`[roachnet:worker] ${stage}`, details ?? {})
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error)
}

async function prettyPrintBootError(error: unknown) {
  if (error instanceof Error) {
    console.error(error.stack ?? error.message)
    return
  }

  console.error(error)
}

const APP_ROOT = new URL('../', import.meta.url)

const IMPORTER = (filePath: string) => {
  bootDebug('importer', { filePath })
  if (filePath.startsWith('./') || filePath.startsWith('../')) {
    return import(new URL(filePath, APP_ROOT).href)
  }
  return import(filePath)
}

type WorkerRecord = {
  key: string
  queue: string
  create: () => Promise<{ handle(job: unknown): Promise<unknown> }>
  concurrency: number
}

function getWorkerDefinitions(): Promise<WorkerRecord[]> {
  return Promise.all([
    import('#jobs/run_download_job'),
    import('#jobs/download_model_job'),
    import('#jobs/run_benchmark_job'),
    import('#jobs/embed_file_job'),
    import('#jobs/check_update_job'),
    import('#jobs/check_service_updates_job'),
  ]).then(
    ([
      { RunDownloadJob },
      { DownloadModelJob },
      { RunBenchmarkJob },
      { EmbedFileJob },
      { CheckUpdateJob },
      { CheckServiceUpdatesJob },
    ]) => [
      {
        key: RunDownloadJob.key,
        queue: RunDownloadJob.queue,
        create: async () => new RunDownloadJob(),
        concurrency: 3,
      },
      {
        key: DownloadModelJob.key,
        queue: DownloadModelJob.queue,
        create: async () => new DownloadModelJob(),
        concurrency: 2,
      },
      {
        key: RunBenchmarkJob.key,
        queue: RunBenchmarkJob.queue,
        create: async () => new RunBenchmarkJob(),
        concurrency: 1,
      },
      {
        key: EmbedFileJob.key,
        queue: EmbedFileJob.queue,
        create: async () => new EmbedFileJob(),
        concurrency: 2,
      },
      {
        key: CheckUpdateJob.key,
        queue: CheckUpdateJob.queue,
        create: async () => new CheckUpdateJob(),
        concurrency: 1,
      },
      {
        key: CheckServiceUpdatesJob.key,
        queue: CheckServiceUpdatesJob.queue,
        create: async () => new CheckServiceUpdatesJob(),
        concurrency: 1,
      },
    ]
  )
}

const ignitor = new Ignitor(APP_ROOT, { importer: IMPORTER })

ignitor.tap((app: any) => {
  app.booting(async () => {
    bootDebug('app:booting:start')
    await import('#start/env')
    bootDebug('app:booting:env-ready')
  })

  app.listen('SIGTERM', () => app.terminate())
  app.listen('SIGINT', () => app.terminate())
})

async function startWorkers() {
  bootDebug('bootstrap:start', {
    appRoot: APP_ROOT.href,
    cwd: process.cwd(),
    nodeEnv: process.env.NODE_ENV,
  })

  const app = ignitor.createApp('console')
  bootDebug('app:create:done')

  await app.init()
  bootDebug('app:init:done')

  await app.boot()
  bootDebug('app:boot:done')

  await app.start(async () => {})
  bootDebug('app:start:done')

  const logger = await app.container.make('logger')
  bootDebug('container:logger:resolved')

  const [{ Worker }, { default: queueConfig }, definitions] = await Promise.all([
    import('bullmq'),
    import('#config/queue'),
    getWorkerDefinitions(),
  ])

  const handlers = new Map<string, Awaited<ReturnType<WorkerRecord['create']>>>()
  for (const definition of definitions) {
    handlers.set(definition.key, await definition.create())
  }

  const workers = await Promise.all(
    Array.from(
      definitions.reduce((queues, definition) => {
        queues.set(definition.queue, definition)
        return queues
      }, new Map<string, WorkerRecord>()).values()
    ).map(async (definition) => {
      const worker = new Worker(
        definition.queue,
        async (job) => {
          logger.info(
            `[${definition.queue}] Processing job: ${job.id} of type: ${job.name}`
          )
          const handler = handlers.get(job.name)
          if (!handler) {
            throw new Error(`No handler found for job: ${job.name}`)
          }

          return handler.handle(job)
        },
        {
          connection: queueConfig.connection,
          concurrency: definition.concurrency,
          autorun: true,
        }
      )

      worker.on('failed', async (job, error) => {
        logger.error(
          `[${definition.queue}] Job failed: ${job?.id}, Error: ${getErrorMessage(error)}`
        )

        if (job?.data?.filetype === 'zim' && job?.data?.url?.includes('wikipedia_en_')) {
          try {
            const { DockerService } = await import('#services/docker_service')
            const { ZimService } = await import('#services/zim_service')
            const dockerService = new DockerService()
            const zimService = new ZimService(dockerService)
            await zimService.onWikipediaDownloadComplete(job.data.url, false)
          } catch (wikipediaError) {
            logger.error(
              `[${definition.queue}] Failed to update Wikipedia status: ${getErrorMessage(wikipediaError)}`
            )
          }
        }
      })

      worker.on('completed', (job) => {
        logger.info(`[${definition.queue}] Job completed: ${job.id}`)
      })

      logger.info(`Worker started for queue: ${definition.queue}`)
      return worker
    })
  )

  const [{ CheckUpdateJob }, { CheckServiceUpdatesJob }] = await Promise.all([
    import('#jobs/check_update_job'),
    import('#jobs/check_service_updates_job'),
  ])

  await CheckUpdateJob.scheduleNightly()
  await CheckServiceUpdatesJob.scheduleNightly()
  logger.info('Queue workers are ready.')

  app.terminating(async () => {
    logger.info('Shutting down queue workers...')
    await Promise.all(workers.map((worker) => worker.close()))
    logger.info('All queue workers shut down gracefully.')
  })
}

void startWorkers().catch((error) => {
  process.exitCode = 1
  bootDebug('worker:start:failed', {
    name: error instanceof Error ? error.name : typeof error,
    message: getErrorMessage(error),
  })
  void prettyPrintBootError(error)
})
