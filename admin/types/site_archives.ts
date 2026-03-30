export interface SiteArchiveRecord {
  slug: string
  title: string
  sourceUrl: string
  entryUrl: string
  createdAt: string
  status: 'ready' | 'blocked'
  note: string | null
}

export interface SiteArchivesResponse {
  archives: SiteArchiveRecord[]
}
