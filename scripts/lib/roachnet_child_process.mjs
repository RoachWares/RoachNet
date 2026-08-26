import { spawn } from 'node:child_process'
import path from 'node:path'

export async function runCommand(command, args, options = {}) {
  let child
  try {
    child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
  } catch (error) {
    throw new Error(`Unable to start ${path.basename(command)}: ${error?.message || String(error)}`)
  }

  let stdout = ''
  let stderr = ''
  child.stdout?.on('data', (chunk) => {
    stdout += chunk.toString()
  })
  child.stderr?.on('data', (chunk) => {
    stderr += chunk.toString()
  })

  const logs = () => ({ stdout: stdout.trim(), stderr: stderr.trim() })
  const formatLogs = typeof options.formatLogs === 'function'
    ? options.formatLogs
    : (label, output) => [output.stdout, output.stderr].filter(Boolean).join('\n')

  await new Promise((resolve, reject) => {
    let settled = false
    const settle = (callback, value) => {
      if (!settled) {
        settled = true
        callback(value)
      }
    }

    child.once('error', (error) => {
      settle(reject, new Error(`Unable to start ${path.basename(command)}: ${error?.message || String(error)}`))
    })
    child.once('close', (exitCode, signal) => {
      if (exitCode === 0) {
        settle(resolve)
        return
      }
      const label = `${path.basename(command)} ${args.join(' ')}`
      const detail = formatLogs(label, logs())
      settle(reject, new Error(detail || `${label} failed with ${signal ? `signal ${signal}` : `exit code ${exitCode ?? 'unknown'}`}`))
    })
  })
}
