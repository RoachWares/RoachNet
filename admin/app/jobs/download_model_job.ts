import { Job, UnrecoverableError } from 'bullmq'
import { QueueService } from '#services/queue_service'
import queueConfig from '#config/queue'
import { createHash } from 'crypto'
import logger from '@adonisjs/core/services/logger'
import { OllamaService } from '#services/ollama_service'

export interface DownloadModelJobParams {
  modelName: string
}

export class DownloadModelJob {
  static get queue() {
    return 'model-downloads'
  }

  static get key() {
    return 'download-model'
  }

  static getJobId(modelName: string): string {
    return createHash('sha256').update(modelName).digest('hex').slice(0, 16)
  }

  async handle(job: Job) {
    const { modelName } = job.data as DownloadModelJobParams

    logger.info(`[DownloadModelJob] Attempting to download model: ${modelName}`)

    const ollamaService = new OllamaService()
    const runtimeStatus = await ollamaService.getRuntimeStatus()
    if (!runtimeStatus.available) {
      logger.warn(
        `[DownloadModelJob] Ollama runtime not ready yet for model ${modelName}. Will retry: ${
          runtimeStatus.error || 'runtime unavailable'
        }`
      )
      throw new Error(runtimeStatus.error || 'Ollama runtime not ready yet')
    }

    logger.info(
      `[DownloadModelJob] Ollama service is reachable at ${runtimeStatus.baseUrl}. Initiating download for ${modelName}`
    )

    // Services are ready, initiate the download with progress tracking
    const result = await ollamaService.downloadModel(modelName, (progressPercent) => {
      if (progressPercent) {
        job.updateProgress(Math.floor(progressPercent))
        logger.info(
          `[DownloadModelJob] Model ${modelName}: ${progressPercent}%`
        )
      }

      // Store detailed progress in job data for clients to query
      job.updateData({
        ...job.data,
        status: 'downloading',
        progress: progressPercent,
        progress_timestamp: new Date().toISOString(),
      })
    })

    if (!result.success) {
      logger.error(
        `[DownloadModelJob] Failed to initiate download for model ${modelName}: ${result.message}`
      )
      // Don't retry errors that will never succeed (e.g., Ollama version too old)
      if (result.retryable === false) {
        throw new UnrecoverableError(result.message)
      }
      throw new Error(`Failed to initiate download for model: ${result.message}`)
    }

    logger.info(`[DownloadModelJob] Successfully completed download for model ${modelName}`)
    return {
      modelName,
      message: result.message,
    }
  }

  static async getByModelName(modelName: string): Promise<Job | undefined> {
    const queueService = new QueueService()
    const queue = queueService.getQueue(this.queue)
    const jobId = this.getJobId(modelName)
    return await queue.getJob(jobId)
  }

  static async dispatch(params: DownloadModelJobParams) {
    const queueService = new QueueService()
    const queue = queueService.getQueue(this.queue)
    const jobId = this.getJobId(params.modelName)

    // Clear any previous failed job so a fresh attempt can be dispatched
    const existing = await queue.getJob(jobId)
    if (existing) {
      const state = await existing.getState()
      if (state === 'failed') {
        await existing.remove()
      }
    }

    try {
      const job = await queue.add(this.key, params, {
        jobId,
        attempts: 40, // Many attempts since services may take considerable time to install
        backoff: {
          type: 'fixed',
          delay: 60000, // Check every 60 seconds
        },
        removeOnComplete: false, // Keep for status checking
        removeOnFail: false, // Keep failed jobs for debugging
      })

      if (queueConfig.disabled) {
        const runner = new DownloadModelJob()
        void Promise.resolve().then(async () => {
          try {
            job.markActive?.()
            await runner.handle(job as Job)
            job.markCompleted?.()
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error)
            job.markFailed?.(message)
          }
        })
      }

      return {
        job,
        created: true,
        message: `Dispatched model download job for ${params.modelName}`,
      }
    } catch (error) {
      if (error.message.includes('job already exists')) {
        const active = await queue.getJob(jobId)
        return {
          job: active,
          created: false,
          message: `Job already exists for model ${params.modelName}`,
        }
      }
      throw error
    }
  }
}
