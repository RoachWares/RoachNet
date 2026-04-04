import { Queue } from 'bullmq'
import { randomUUID } from 'node:crypto'
import queueConfig from '#config/queue'

class InMemoryQueueJob {
  public progress = 0
  public failedReason: string | undefined
  private state = 'waiting'

  constructor(
    private readonly queue: InMemoryQueue,
    public readonly id: string,
    public readonly name: string,
    public data: Record<string, any>
  ) {}

  async updateProgress(progress: number) {
    this.progress = Number(progress) || 0
  }

  async updateData(data: Record<string, any>) {
    this.data = data
  }

  async getState() {
    return this.state
  }

  async remove() {
    this.queue.removeJob(this.id)
  }

  markActive() {
    this.state = 'active'
  }

  markDelayed() {
    this.state = 'delayed'
  }

  markCompleted() {
    this.state = 'completed'
    this.failedReason = undefined
  }

  markFailed(reason: string) {
    this.state = 'failed'
    this.failedReason = reason
  }
}

class InMemoryQueue {
  private jobs = new Map<string, InMemoryQueueJob>()

  constructor(private readonly name: string) {}

  async add(jobName: string, data: Record<string, any>, options: Record<string, any> = {}) {
    const jobId = String(options.jobId || randomUUID())
    if (this.jobs.has(jobId)) {
      throw new Error('job already exists')
    }

    const job = new InMemoryQueueJob(this, jobId, jobName, data)
    this.jobs.set(jobId, job)
    return job
  }

  async getJob(jobId: string) {
    return this.jobs.get(String(jobId))
  }

  async getJobs(states: string[]) {
    const allowedStates = new Set(states)
    const jobs = Array.from(this.jobs.values())
    const filtered = []

    for (const job of jobs) {
      const state = await job.getState()
      if (allowedStates.has(state)) {
        filtered.push(job)
      }
    }

    return filtered
  }

  async upsertJobScheduler() {
    return { id: `${this.name}:scheduler` }
  }

  async close() {
    this.jobs.clear()
  }

  removeJob(jobId: string) {
    this.jobs.delete(String(jobId))
  }
}

export class QueueService {
  private queues: Map<string, any> = new Map()

  getQueue(name: string): any {
    if (!this.queues.has(name)) {
      const queue = queueConfig.disabled
        ? new InMemoryQueue(name)
        : new Queue(name, {
            connection: queueConfig.connection!,
          })
      this.queues.set(name, queue)
    }
    return this.queues.get(name)!
  }

  async close() {
    for (const queue of this.queues.values()) {
      await queue.close()
    }
  }
}
