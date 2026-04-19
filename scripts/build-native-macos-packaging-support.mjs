import { createHash } from 'node:crypto'
import { createReadStream, writeFileSync } from 'node:fs'
import path from 'node:path'

async function computeSha256Hex(filePath) {
  return await new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    const stream = createReadStream(filePath)

    stream.on('error', reject)
    stream.on('data', (chunk) => {
      hash.update(chunk)
    })
    stream.on('end', () => {
      resolve(hash.digest('hex'))
    })
  })
}

export async function writeSha256Sidecar(artifactPath) {
  const digest = await computeSha256Hex(artifactPath)
  const sidecarPath = `${artifactPath}.sha256`

  writeFileSync(sidecarPath, `${digest}  ${path.basename(artifactPath)}\n`, 'utf8')
  return sidecarPath
}
