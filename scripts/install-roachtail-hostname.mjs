#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { access, readFile, writeFile } from 'node:fs/promises'
import process from 'node:process'
import {
  applyRoachNetLocalAliasToHosts,
  buildRoachNetLocalAliasShellCommand,
  getRoachNetLocalHostname,
  hostsFileHasRoachNetLocalAlias,
  roachNetHostnameResolvesToLoopback,
} from './lib/roachtail_hostname.mjs'

const args = new Set(process.argv.slice(2))
const interactive = args.has('--interactive')
const printCommand = args.has('--print-command')
const hostname = getRoachNetLocalHostname(process.env)
const hostsFile = process.env.ROACHNET_HOSTS_FILE?.trim() || '/etc/hosts'

function shellQuoteAppleScript(value) {
  return String(value).replaceAll('\\', '\\\\').replaceAll('"', '\\"')
}

function run(binary, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''
    child.stdout?.on('data', (chunk) => {
      stdout += chunk.toString()
    })
    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString()
    })
    child.once('error', reject)
    child.once('close', (code) => {
      if (code === 0) {
        resolve({ stdout, stderr })
        return
      }

      reject(
        new Error(
          `${binary} ${args.join(' ')} failed with exit code ${code}\n${stderr.trim() || stdout.trim()}`
        )
      )
    })
  })
}

async function flushResolverCache() {
  if (process.platform !== 'darwin') {
    return
  }

  await run('/bin/sh', ['-lc', 'dscacheutil -flushcache >/dev/null 2>&1 || true; killall -HUP mDNSResponder >/dev/null 2>&1 || true'])
}

async function applyDirectWrite() {
  const current = await readFile(hostsFile, 'utf8')
  const next = applyRoachNetLocalAliasToHosts(current, hostname)
  if (next !== current) {
    await writeFile(hostsFile, next, 'utf8')
  }
  await flushResolverCache()
}

async function applyInteractivePrivilegedWrite() {
  if (process.platform !== 'darwin') {
    throw new Error('Interactive RoachTail hostname provisioning is only implemented for macOS.')
  }

  const shellCommand = `/bin/zsh -lc '${buildRoachNetLocalAliasShellCommand(hostname, hostsFile).replace(/'/g, `'\"'\"'`)}'`
  const appleScript = `do shell script "${shellQuoteAppleScript(shellCommand)}" with administrator privileges`
  await run('osascript', ['-e', appleScript])
}

async function main() {
  if (printCommand) {
    process.stdout.write(`${buildRoachNetLocalAliasShellCommand(hostname, hostsFile)}\n`)
    return
  }

  let currentHosts = ''
  try {
    currentHosts = await readFile(hostsFile, 'utf8')
  } catch (error) {
    throw new Error(`RoachNet could not read ${hostsFile}: ${error instanceof Error ? error.message : String(error)}`)
  }

  if (hostsFileHasRoachNetLocalAlias(currentHosts, hostname)) {
    if (hostsFile === '/etc/hosts') {
      await flushResolverCache()
      const resolved = await roachNetHostnameResolvesToLoopback(hostname)
      process.stdout.write(
        JSON.stringify({
          ok: true,
          hostname,
          hostsFile,
          changed: false,
          resolved,
        }) + '\n'
      )
      return
    }

    process.stdout.write(
      JSON.stringify({
        ok: true,
        hostname,
        hostsFile,
        changed: false,
        resolved: null,
      }) + '\n'
    )
    return
  }

  try {
    await access(hostsFile, process.platform === 'win32' ? undefined : 2)
    await applyDirectWrite()
  } catch (error) {
    if (!interactive) {
      throw new Error(
        `RoachNet could not update ${hostsFile} without elevated access. Re-run with --interactive or provision the RoachTail alias manually. ${
          error instanceof Error ? error.message : String(error)
        }`
      )
    }

    await applyInteractivePrivilegedWrite()
  }

  const resolved = hostsFile === '/etc/hosts' ? await roachNetHostnameResolvesToLoopback(hostname) : null
  process.stdout.write(
    JSON.stringify({
      ok: true,
      hostname,
      hostsFile,
      changed: true,
      resolved,
    }) + '\n'
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
})
