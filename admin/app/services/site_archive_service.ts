import { inject } from '@adonisjs/core'
import env from '#start/env'
import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import type { SiteArchiveRecord } from '../../types/site_archives.js'

const BLOCKED_MEDIA_HOSTS = new Set([
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtu.be',
  'soundcloud.com',
  'www.soundcloud.com',
])

const MIME_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.gif': 'image/gif',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
}

@inject()
export class SiteArchiveService {
  private getStorageRoot() {
    const storageBase = env.get('NOMAD_STORAGE_PATH') || path.join(process.cwd(), 'storage')
    return path.resolve(storageBase, 'site-archives')
  }

  private getManifestPath() {
    return path.join(this.getStorageRoot(), 'index.json')
  }

  private getSitesRoot() {
    return path.join(this.getStorageRoot(), 'sites')
  }

  private getArchiveDirectory(slug: string) {
    return path.join(this.getSitesRoot(), slug)
  }

  public async listArchives(): Promise<SiteArchiveRecord[]> {
    return (await this.readManifest()).sort((left, right) =>
      right.createdAt.localeCompare(left.createdAt)
    )
  }

  public async createArchive(input: { url: string; title?: string | null }): Promise<SiteArchiveRecord> {
    const normalizedUrl = this.normalizeUrl(input.url)
    const hostname = normalizedUrl.hostname.toLowerCase()

    if (BLOCKED_MEDIA_HOSTS.has(hostname)) {
      throw new Error(
        'RoachNet does not bulk-download streaming media from YouTube or SoundCloud. Archive standard websites or self-hosted/public content you are allowed to copy.'
      )
    }

    const manifest = await this.readManifest()
    const slug = this.buildSlug(normalizedUrl)
    const archiveDir = this.getArchiveDirectory(slug)
    await mkdir(this.getSitesRoot(), { recursive: true })
    await rm(archiveDir, { recursive: true, force: true })

    const websiteScraper = (await import('website-scraper')).default as any
    await websiteScraper({
      urls: [{ url: normalizedUrl.toString(), filename: 'index.html' }],
      directory: archiveDir,
      recursive: true,
      maxDepth: 2,
      requestConcurrency: 4,
      prettifyUrls: false,
    })

    const record: SiteArchiveRecord = {
      slug,
      title: input.title?.trim() || normalizedUrl.hostname,
      sourceUrl: normalizedUrl.toString(),
      entryUrl: `/site-archives/${slug}/index.html`,
      createdAt: new Date().toISOString(),
      status: 'ready',
      note: 'Archived for offline browsing inside RoachNet.',
    }

    await this.writeManifest([...manifest.filter((archive) => archive.slug !== slug), record])
    return record
  }

  public async deleteArchive(slug: string): Promise<void> {
    const manifest = await this.readManifest()
    const nextManifest = manifest.filter((archive) => archive.slug !== slug)
    await rm(this.getArchiveDirectory(slug), { recursive: true, force: true })
    await this.writeManifest(nextManifest)
  }

  public async resolveArchiveFile(slug: string, requestedPath?: string | null) {
    const relativePath = requestedPath && requestedPath.trim() !== '' ? requestedPath : 'index.html'
    const archiveDir = this.getArchiveDirectory(slug)
    const resolvedPath = path.resolve(archiveDir, relativePath)

    if (!resolvedPath.startsWith(archiveDir)) {
      throw new Error('Invalid archive path.')
    }

    await stat(resolvedPath)
    return resolvedPath
  }

  public async readArchiveHtml(slug: string, requestedPath?: string | null) {
    const filePath = await this.resolveArchiveFile(slug, requestedPath)
    const html = await readFile(filePath, 'utf8')
    const baseHref = `/site-archives/${slug}/`

    if (html.includes('<base ')) {
      return html
    }

    if (html.includes('<head>')) {
      return html.replace('<head>', `<head><base href="${baseHref}">`)
    }

    return `<base href="${baseHref}">${html}`
  }

  public createArchiveStream(slug: string, requestedPath?: string | null) {
    return this.resolveArchiveFile(slug, requestedPath).then((filePath) => ({
      filePath,
      stream: createReadStream(filePath),
      contentType: MIME_TYPES[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
    }))
  }

  private async readManifest(): Promise<SiteArchiveRecord[]> {
    const manifestPath = this.getManifestPath()
    await mkdir(this.getSitesRoot(), { recursive: true })

    try {
      return JSON.parse(await readFile(manifestPath, 'utf8'))
    } catch {
      return []
    }
  }

  private async writeManifest(records: SiteArchiveRecord[]) {
    await mkdir(this.getStorageRoot(), { recursive: true })
    await writeFile(this.getManifestPath(), JSON.stringify(records, null, 2) + '\n', 'utf8')
  }

  private normalizeUrl(rawUrl: string) {
    const candidate = rawUrl.trim()
    if (!candidate) {
      throw new Error('A website URL is required.')
    }

    const withScheme = /^https?:\/\//i.test(candidate) ? candidate : `https://${candidate}`
    const parsed = new URL(withScheme)

    if (!['http:', 'https:'].includes(parsed.protocol)) {
      throw new Error('Only http and https URLs can be archived.')
    }

    return parsed
  }

  private buildSlug(url: URL) {
    const base = `${url.hostname}${url.pathname}`
      .replace(/[^a-z0-9]+/gi, '-')
      .replace(/^-+|-+$/g, '')
      .toLowerCase()
      .slice(0, 48) || 'site'

    const suffix = createHash('sha1').update(url.toString()).digest('hex').slice(0, 8)
    return `${base}-${suffix}`
  }
}
