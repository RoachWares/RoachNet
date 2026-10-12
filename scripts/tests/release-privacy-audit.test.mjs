// The release privacy audit: it finds a build Mac's paths, host name and LAN
// address in shipped files (zipped ones too), ignores look-alikes inside
// longer words, and reports by kind without printing the values. Every
// machine detail here is made up.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { buildMachineNeedles, scan } from '../audit-release-privacy.mjs'

const machine = {
  home: '/Users/sample-builder',
  root: '/Volumes/SampleDisk/Work/RoachNet',
  hostNames: ['Sample-Laptop.local', 'roachnet'],
  addresses: [
    { family: 'IPv4', address: '192.168.77.41', internal: false, mac: 'aa:bb:cc:dd:ee:01' },
    { family: 'IPv4', address: '127.0.0.1', internal: true, mac: '00:00:00:00:00:00' },
    { family: 'IPv4', address: '203.0.113.9', internal: false, mac: '00:00:00:00:00:00' },
  ],
}

test('the needles come from the machine, and product words are skipped', () => {
  const needles = buildMachineNeedles(machine)
  const kinds = new Set(needles.map((needle) => needle.kind))
  for (const kind of ['home folder path', 'workspace path', 'build volume path', 'host name', 'LAN address', 'network hardware address']) {
    assert.ok(kinds.has(kind), kind)
  }
  assert.ok(!needles.some((needle) => needle.text.toLowerCase() === 'roachnet'), 'a host named like the product would match everything')
  assert.ok(!needles.some((needle) => needle.text === '203.0.113.9'), 'only private addresses count as LAN addresses')
})

test('a bundle carrying build-machine details fails, look-alikes pass', () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'rn-privacy-test-'))
  try {
    const bundle = path.join(root, 'Sample.app', 'Contents')
    mkdirSync(path.join(bundle, 'MacOS'), { recursive: true })
    mkdirSync(path.join(bundle, 'Resources'), { recursive: true })
    writeFileSync(path.join(bundle, 'MacOS', 'Sample'), Buffer.concat([
      Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0, 0]), Buffer.from('/Volumes/SampleDisk/Work/RoachNet/Sources/A.swift\0'),
    ]))
    writeFileSync(path.join(bundle, 'Resources', 'log.txt'), 'served from SAMPLE-LAPTOP at 192.168.77.41:38111\n')
    writeFileSync(path.join(bundle, 'Resources', 'clean.txt'), 'sample-laptops 192.168.77.410 192.168.77.4 Users/sample-builderx\n')
    const findings = scan([path.join(root, 'Sample.app')], buildMachineNeedles(machine))
    const byFile = (name) => findings.filter((finding) => finding.file.endsWith(name)).map((finding) => finding.kind).sort()
    assert.deepEqual(byFile('MacOS/Sample'), ['build volume path', 'workspace path'])
    assert.deepEqual(byFile('log.txt'), ['LAN address', 'host name'])
    assert.deepEqual(byFile('clean.txt'), [])
    assert.ok(findings.every((finding) => !finding.file.includes(root)), 'files are shown without this Mac’s temp path')
    for (const finding of findings) {
      assert.ok(!JSON.stringify(finding).includes('SampleDisk') && !JSON.stringify(finding).includes('192.168'), 'values are never reported')
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('details inside a zipped app are found', { skip: process.platform !== 'darwin' && 'needs ditto' }, () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'rn-privacy-zip-'))
  try {
    const inner = path.join(root, 'stage', 'Inner.app', 'Contents')
    mkdirSync(inner, { recursive: true })
    writeFileSync(path.join(inner, 'Info.plist'), '<string>/Users/sample-builder/Desktop</string>')
    mkdirSync(path.join(root, 'Outer'), { recursive: true })
    execFileSync('ditto', ['-c', '-k', '--keepParent', path.join(root, 'stage', 'Inner.app'), path.join(root, 'Outer', 'Inner.zip')])
    const findings = scan([path.join(root, 'Outer')], buildMachineNeedles(machine))
    assert.deepEqual(findings.map((finding) => finding.kind), ['home folder path'])
    assert.match(findings[0].file, /^Outer\/Inner\.zip!\/Inner\.app\/Contents\/Info\.plist$/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
