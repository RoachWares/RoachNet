declare module 'website-scraper' {
  export interface ScrapeTarget {
    url: string
    filename?: string
  }

  export interface ScrapeOptions {
    urls: ScrapeTarget[]
    directory: string
    recursive?: boolean
    maxDepth?: number
    requestConcurrency?: number
    prettifyUrls?: boolean
  }

  export default function scrape(options: ScrapeOptions): Promise<void>
}
