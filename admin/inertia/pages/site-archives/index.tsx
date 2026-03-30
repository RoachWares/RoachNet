import { Head } from '@inertiajs/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import AppLayout from '~/layouts/AppLayout'
import Input from '~/components/inputs/Input'
import StyledButton from '~/components/StyledButton'
import Alert from '~/components/Alert'
import { useNotifications } from '~/context/NotificationContext'
import useInternetStatus from '~/hooks/useInternetStatus'
import api from '~/lib/api'
import type { SiteArchiveRecord } from '../../../types/site_archives'

export default function SiteArchivesPage() {
  const queryClient = useQueryClient()
  const { addNotification } = useNotifications()
  const { isOnline } = useInternetStatus()
  const [url, setUrl] = useState('')
  const [title, setTitle] = useState('')

  const archivesQuery = useQuery({
    queryKey: ['site-archives'],
    queryFn: () => api.listSiteArchives(),
    staleTime: 10_000,
  })

  const createArchiveMutation = useMutation({
    mutationFn: () => api.createSiteArchive(url.trim(), title.trim() || undefined),
    onSuccess: async () => {
      setUrl('')
      setTitle('')
      addNotification({
        type: 'success',
        message: 'Website archived for offline browsing.',
      })
      await queryClient.invalidateQueries({ queryKey: ['site-archives'] })
    },
    onError: (error) => {
      addNotification({
        type: 'error',
        message: error instanceof Error ? error.message : 'Failed to archive website.',
      })
    },
  })

  const deleteArchiveMutation = useMutation({
    mutationFn: (slug: string) => api.deleteSiteArchive(slug),
    onSuccess: async () => {
      addNotification({
        type: 'success',
        message: 'Archived site removed.',
      })
      await queryClient.invalidateQueries({ queryKey: ['site-archives'] })
    },
    onError: (error) => {
      addNotification({
        type: 'error',
        message: error instanceof Error ? error.message : 'Failed to remove archived site.',
      })
    },
  })

  return (
    <AppLayout>
      <Head title="Offline Web Apps | RoachNet" />
      <div className="p-4 md:p-6 space-y-6">
        <section className="roachnet-card rounded-[2rem] border border-border-default p-6 md:p-8">
          <div className="space-y-4">
            <p className="roachnet-kicker text-xs text-desert-green-light">Offline Web Apps</p>
            <h1 className="text-4xl font-semibold uppercase tracking-[0.12em] text-text-primary md:text-5xl">
              Archive standard websites into local offline applications.
            </h1>
            <p className="max-w-4xl text-base leading-7 text-text-secondary">
              RoachNet can mirror standard websites and keep the saved copy browsable on the local
              box later without internet access.
            </p>
          </div>
        </section>

        <Alert
          type="warning"
          variant="bordered"
          title="Lawful-use boundary"
          message="This archive tool is for websites and content you are allowed to copy. RoachNet does not bulk-download streaming media from YouTube or SoundCloud."
        />

        {!isOnline && (
          <Alert
            type="info"
            variant="bordered"
            title="Offline Mode"
            message="You can still browse previously archived sites. New archives require an internet connection."
          />
        )}

        <section className="roachnet-card rounded-[1.75rem] border border-border-default p-6 md:p-7">
          <div className="grid gap-4 lg:grid-cols-[1.3fr_0.7fr]">
            <Input
              name="archiveUrl"
              label="Website URL"
              value={url}
              onChange={(event) => setUrl(event.target.value)}
              placeholder="https://example.com"
              helpText="Enter a standard website URL. RoachNet will mirror the page and its local assets into storage/site-archives."
            />
            <Input
              name="archiveTitle"
              label="Application Label"
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder="Example Site"
              helpText="Optional. Leave blank to use the host name."
            />
          </div>

          <div className="mt-4 flex flex-wrap gap-3">
            <StyledButton
              onClick={() => createArchiveMutation.mutate()}
              loading={createArchiveMutation.isPending}
              disabled={!isOnline || url.trim().length === 0}
              icon="IconWorldDownload"
            >
              Archive Site
            </StyledButton>
          </div>
        </section>

        <section className="grid grid-cols-1 gap-4 xl:grid-cols-2">
          {(archivesQuery.data?.archives || []).map((archive: SiteArchiveRecord) => (
            <article
              key={archive.slug}
              className="roachnet-card rounded-[1.5rem] border border-border-default p-6"
            >
              <div className="space-y-3">
                <div>
                  <p className="text-xl font-semibold text-text-primary">{archive.title}</p>
                  <p className="text-sm text-text-muted break-all">{archive.sourceUrl}</p>
                </div>
                <p className="text-sm text-text-secondary">{archive.note || 'Archived site ready.'}</p>
                <p className="text-xs uppercase tracking-[0.16em] text-text-muted">
                  Saved {new Date(archive.createdAt).toLocaleString()}
                </p>
                <div className="flex flex-wrap gap-3">
                  <StyledButton
                    onClick={() => {
                      window.location.href = archive.entryUrl
                    }}
                    icon="IconExternalLink"
                  >
                    Open Offline App
                  </StyledButton>
                  <StyledButton
                    variant="ghost"
                    onClick={() => deleteArchiveMutation.mutate(archive.slug)}
                    loading={deleteArchiveMutation.isPending}
                    icon="IconTrash"
                  >
                    Remove
                  </StyledButton>
                </div>
              </div>
            </article>
          ))}

          {(archivesQuery.data?.archives || []).length === 0 && !archivesQuery.isLoading && (
            <div className="roachnet-card rounded-[1.5rem] border border-border-default p-6 text-text-secondary">
              No archived sites yet.
            </div>
          )}
        </section>
      </div>
    </AppLayout>
  )
}
