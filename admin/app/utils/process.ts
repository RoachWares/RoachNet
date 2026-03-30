import { spawn } from 'node:child_process'

export async function findCommandPath(binary: string): Promise<string | null> {
  const lookupBinary = process.platform === 'win32' ? 'where' : 'which'

  return new Promise((resolve) => {
    const child = spawn(lookupBinary, [binary], {
      env: process.env,
      stdio: ['ignore', 'pipe', 'ignore'],
    })

    let stdout = ''

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString()
    })

    child.on('error', () => resolve(null))
    child.on('close', (code) => {
      if (code !== 0) {
        resolve(null)
        return
      }

      resolve(stdout.split(/\r?\n/).find(Boolean)?.trim() || null)
    })
  })
}
