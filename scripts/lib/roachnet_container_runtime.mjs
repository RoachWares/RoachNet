#!/usr/bin/env node

import { createHash } from 'node:crypto'
import process from 'node:process'

export const DOCKER_DOCS = {
  desktop: 'https://docs.docker.com/desktop/',
  composeUp: 'https://docs.docker.com/reference/cli/docker/compose/up/',
  composeFile: 'https://docs.docker.com/reference/compose-file/',
  desktopWindowsWsl: 'https://docs.docker.com/desktop/features/wsl/',
}

const START_TIMEOUT_MS = 180_000
const POLL_INTERVAL_MS = 2_000

function hashValue(value) {
  return createHash('sha256').update(String(value)).digest('hex')
}

export function getRoachNetComposeProjectName(installPath) {
  return `roachnet-${hashValue(installPath).slice(0, 10)}`
}

function parseDesktopStatusOutput(raw) {
  if (!raw) {
    return 'unknown'
  }

  try {
    const parsed = JSON.parse(raw)
    return parsed?.status || parsed?.Status || 'unknown'
  } catch {
    const normalized = raw.trim().toLowerCase()
    if (normalized.includes('running')) {
      return 'running'
    }
    if (normalized.includes('stopped')) {
      return 'stopped'
    }
    return normalized || 'unknown'
  }
}

export async function detectRoachNetContainerRuntime({
  commandPath,
  commandExists,
  runProcess,
}) {
  const dockerCliPath = await commandPath('docker')
  const composeAvailable = dockerCliPath
    ? await commandExists('docker', ['compose', 'version'])
    : false
  const daemonRunning = dockerCliPath ? await commandExists('docker', ['info']) : false
  const desktopCapable = process.platform === 'darwin' || process.platform === 'win32'
  let desktopCliAvailable = false
  let desktopStatus = desktopCapable ? 'unavailable' : 'unsupported'

  if (dockerCliPath && desktopCapable) {
    try {
      await runProcess('docker', ['desktop', 'version'])
      desktopCliAvailable = true
    } catch {
      desktopCliAvailable = false
    }
  }

  if (desktopCliAvailable) {
    try {
      const result = await runProcess('docker', ['desktop', 'status', '--format', 'json'])
      desktopStatus = parseDesktopStatusOutput(result.stdout)
    } catch {
      desktopStatus = daemonRunning ? 'running' : 'stopped'
    }
  } else if (desktopCapable) {
    desktopStatus = daemonRunning ? 'running' : 'stopped'
  }

  return {
    integrationName: 'RoachNet Container Runtime',
    dockerCliPath,
    composeAvailable,
    daemonRunning,
    desktopCapable,
    desktopCliAvailable,
    desktopStatus,
    ready: Boolean(dockerCliPath && composeAvailable && daemonRunning),
    docs: DOCKER_DOCS,
  }
}

export async function startRoachNetContainerRuntime({
  commandExists,
  detectRuntime,
  runProcess,
  runShell,
  log = () => {},
  env = process.env,
  timeoutMs = START_TIMEOUT_MS,
}) {
  const runtime = await detectRuntime()
  if (runtime.ready) {
    log('RoachNet Container Runtime is already ready.')
    return runtime
  }

  if (!runtime.dockerCliPath) {
    throw new Error('Docker CLI is not installed yet, so the RoachNet Container Runtime cannot start.')
  }

  log('RoachNet Container Runtime is not ready. Attempting automatic startup...')

  if (runtime.desktopCliAvailable) {
    log('Starting Docker Desktop through the Docker CLI...')
    await runProcess(
      'docker',
      ['desktop', 'start', '--timeout', String(Math.max(30, Math.ceil(timeoutMs / 1000)))],
      { env }
    )
  } else if (process.platform === 'darwin') {
    log('Starting Docker Desktop through macOS application launch...')
    await runProcess('open', ['-a', 'Docker'], { env })
  } else if (process.platform === 'win32') {
    log('Starting Docker Desktop through Windows process launch...')
    await runProcess('powershell', ['-NoProfile', '-Command', "Start-Process 'Docker Desktop'"], {
      env,
    })
  } else {
    log('Starting Docker service through systemctl...')
    await runShell('sudo systemctl start docker', { env })
  }

  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    const nextRuntime = await detectRuntime()
    if (nextRuntime.ready) {
      log('RoachNet Container Runtime is ready.')
      return nextRuntime
    }

    if (nextRuntime.dockerCliPath && !nextRuntime.composeAvailable) {
      throw new Error(
        'Docker CLI is available, but `docker compose` is not. Install Docker Compose v2 before continuing.'
      )
    }

    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS))
  }

  throw new Error(
    'RoachNet timed out while waiting for the container runtime to become ready. Check Docker Desktop or the Docker service and retry.'
  )
}

function buildComposeArgs({
  projectName,
  composeFiles,
  commandArgs,
}) {
  const args = []

  if (projectName) {
    args.push('-p', projectName)
  }

  for (const composeFile of composeFiles) {
    args.push('-f', composeFile)
  }

  args.push(...commandArgs)
  return args
}

export async function composeUpRoachNetServices({
  composeFiles,
  cwd,
  installPath,
  runProcess,
  env = process.env,
  onStdout,
  onStderr,
  waitTimeoutMs = START_TIMEOUT_MS,
  services = [],
  dryRun = false,
  build = false,
}) {
  const args = buildComposeArgs({
    projectName: getRoachNetComposeProjectName(installPath),
    composeFiles,
    commandArgs: [
      ...(dryRun ? ['--dry-run'] : []),
      'up',
      '-d',
      ...(build ? ['--build'] : []),
      '--remove-orphans',
      '--wait',
      '--wait-timeout',
      String(Math.max(30, Math.ceil(waitTimeoutMs / 1000))),
      ...services,
    ],
  })

  return runProcess('docker', ['compose', ...args], {
    cwd,
    env,
    onStdout,
    onStderr,
  })
}

export async function composePreviewRoachNetServices({
  composeFiles,
  cwd,
  installPath,
  runProcess,
  env = process.env,
  onStdout,
  onStderr,
  services = [],
}) {
  return composeUpRoachNetServices({
    composeFiles,
    cwd,
    installPath,
    runProcess,
    env,
    onStdout,
    onStderr,
    services,
    dryRun: true,
  })
}
