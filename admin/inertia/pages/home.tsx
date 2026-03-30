import {
  IconAntennaBars5,
  IconBolt,
  IconCpu2,
  IconDatabase,
  IconHelp,
  IconMapRoute,
  IconPlus,
  IconSettings,
  IconShieldLock,
  IconWifiOff,
} from '@tabler/icons-react'
import { Head, usePage } from '@inertiajs/react'
import AppLayout from '~/layouts/AppLayout'
import { getServiceLink } from '~/lib/navigation'
import { ServiceSlim } from '../../types/services'
import DynamicIcon, { DynamicIconName } from '~/components/DynamicIcon'
import { useUpdateAvailable } from '~/hooks/useUpdateAvailable'
import { useSystemSetting } from '~/hooks/useSystemSetting'
import Alert from '~/components/Alert'
import { SERVICE_NAMES } from '../../constants/service_names'
import useAIRuntimeStatus from '~/hooks/useAIRuntimeStatus'
import useInternetStatus from '~/hooks/useInternetStatus'

// Maps is a Core Capability (display_order: 4)
const MAPS_ITEM = {
  label: 'Maps',
  to: '/maps',
  target: '',
  description: 'View offline maps',
  icon: <IconMapRoute size={48} />,
  installed: true,
  displayOrder: 4,
  poweredBy: null,
}

// System items shown after all apps
const SYSTEM_ITEMS = [
  {
    label: 'AI Control',
    to: '/settings/ai',
    target: '',
    description: 'Link Ollama and OpenClaw runtimes, verify endpoints, and tune local AI access.',
    icon: <IconCpu2 size={48} />,
    installed: true,
    displayOrder: 50,
    poweredBy: null,
  },
  {
    label: 'Easy Setup',
    to: '/easy-setup',
    target: '',
    description:
      'Use the guided setup flow to connect runtimes, download content, and stage your offline toolkit.',
    icon: <IconBolt size={48} />,
    installed: true,
    displayOrder: 51,
    poweredBy: null,
  },
  {
    label: 'Offline Web Apps',
    to: '/site-archives',
    target: '',
    description: 'Mirror standard websites into browseable offline local web apps.',
    icon: <IconDatabase size={48} />,
    installed: true,
    displayOrder: 52,
    poweredBy: null,
  },
  {
    label: 'Install Apps',
    to: '/settings/apps',
    target: '',
    description: 'Not seeing your favorite app? Install it here!',
    icon: <IconPlus size={48} />,
    installed: true,
    displayOrder: 53,
    poweredBy: null,
  },
  {
    label: 'Docs',
    to: '/docs/home',
    target: '',
    description: 'Read RoachNet manuals, deployment notes, and field references.',
    icon: <IconHelp size={48} />,
    installed: true,
    displayOrder: 54,
    poweredBy: null,
  },
  {
    label: 'Settings',
    to: '/settings/system',
    target: '',
    description: 'Tune RoachNet, providers, storage paths, and local services.',
    icon: <IconSettings size={48} />,
    installed: true,
    displayOrder: 55,
    poweredBy: null,
  },
]

interface DashboardItem {
  label: string
  to: string
  target: string
  description: string
  icon: React.ReactNode
  installed: boolean
  displayOrder: number
  poweredBy: string | null
}

export default function Home(props: {
  system: {
    services: ServiceSlim[]
  }
}) {
  const items: DashboardItem[] = []
  const updateInfo = useUpdateAvailable()
  const { aiAssistantName } = usePage<{ aiAssistantName: string }>().props
  const aiRuntimeStatus = useAIRuntimeStatus('ollama')
  const openClawRuntimeStatus = useAIRuntimeStatus('openclaw')
  const { isOnline } = useInternetStatus()

  // Check if user has visited Easy Setup
  const { data: easySetupVisited } = useSystemSetting({
    key: 'ui.hasVisitedEasySetup'
  })
  const shouldHighlightEasySetup = easySetupVisited?.value ? String(easySetupVisited.value) !== 'true' : false

  // Add installed services (non-dependency services only)
  props.system.services
    .filter((service) => service.installed && service.ui_location)
    .forEach((service) => {
      items.push({
        // Inject custom AI Assistant name if this is the chat service
        label: service.service_name === SERVICE_NAMES.OLLAMA && aiAssistantName ? aiAssistantName : (service.friendly_name || service.service_name),
        to: service.ui_location ? getServiceLink(service.ui_location) : '#',
        target: '_blank',
        description:
          service.description ||
          `Access the ${service.friendly_name || service.service_name} application`,
        icon: service.icon ? (
          <DynamicIcon icon={service.icon as DynamicIconName} className="!size-12" />
        ) : (
          <IconWifiOff size={48} />
        ),
        installed: service.installed,
        displayOrder: service.display_order ?? 100,
        poweredBy: service.powered_by ?? null,
      })
    })

  // Add Maps as a Core Capability
  items.push(MAPS_ITEM)

  // Add system items
  items.push(...SYSTEM_ITEMS)

  // Sort all items by display order
  items.sort((a, b) => a.displayOrder - b.displayOrder)

  return (
    <AppLayout>
      <Head title="RoachNet Command Grid" />
      <div className="p-4 md:p-6 space-y-6">
        {updateInfo?.updateAvailable && (
          <div className="flex justify-center items-center w-full">
            <Alert
              title="A RoachNet update is available."
              type="info-inverted"
              variant="solid"
              className="w-full"
              buttonProps={{
                variant: 'primary',
                children: 'Go to Settings',
                icon: 'IconSettings',
                onClick: () => {
                  window.location.href = '/settings/update'
                },
              }}
            />
          </div>
        )}

        <section className="roachnet-card rounded-[2rem] border border-border-default p-6 md:p-8">
          <div className="grid gap-6 xl:grid-cols-[1.35fr_0.85fr]">
            <div className="space-y-4">
              <p className="roachnet-kicker text-xs text-desert-green-light">Offline Command Grid</p>
              <h2 className="text-4xl font-semibold uppercase tracking-[0.12em] text-text-primary md:text-5xl">
                RoachNet keeps your maps, archives, and local AI online when everything else drops.
              </h2>
              <p className="max-w-3xl text-base leading-7 text-text-secondary md:text-lg">
                Run field-ready tools, browse offline references, manage local models, and keep
                your day-to-day workflows moving without depending on an external network.
              </p>
            </div>

            <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-1">
              <div className="rounded-[1.35rem] border border-border-default bg-surface-secondary/90 p-4">
                <p className="roachnet-kicker text-[0.68rem] text-text-muted">Network State</p>
                <div className="mt-2 flex items-center gap-3">
                  <IconAntennaBars5 className="size-5 text-desert-green-light" />
                  <div>
                    <div className="text-lg font-semibold text-text-primary">
                      {isOnline ? 'Internet Detected' : 'Offline Mode'}
                    </div>
                    <div className="text-sm text-text-secondary">
                      {isOnline
                        ? 'RoachNet can fetch updates and content packs.'
                        : 'Local tools remain accessible inside the grid.'}
                    </div>
                  </div>
                </div>
              </div>

              <div className="rounded-[1.35rem] border border-border-default bg-surface-secondary/90 p-4">
                <p className="roachnet-kicker text-[0.68rem] text-text-muted">AI Runtime</p>
                <div className="mt-2 flex items-center gap-3">
                  <IconCpu2 className="size-5 text-desert-orange-light" />
                  <div>
                    <div className="text-lg font-semibold text-text-primary">
                      {aiRuntimeStatus.available ? aiAssistantName : 'Runtime Not Linked'}
                    </div>
                    <div className="text-sm text-text-secondary">
                      {aiRuntimeStatus.available
                        ? `Connected via ${aiRuntimeStatus.source} at ${aiRuntimeStatus.baseUrl}`
                        : 'Use AI Control or Easy Setup to connect a local or managed runtime.'}
                    </div>
                    <div className="mt-2 text-xs uppercase tracking-[0.16em] text-text-muted">
                      {openClawRuntimeStatus.available
                        ? `OpenClaw linked at ${openClawRuntimeStatus.baseUrl}`
                        : 'OpenClaw not linked yet'}
                    </div>
                  </div>
                </div>
              </div>

              <div className="rounded-[1.35rem] border border-border-default bg-surface-secondary/90 p-4">
                <p className="roachnet-kicker text-[0.68rem] text-text-muted">Storage & Archives</p>
                <div className="mt-2 flex items-center gap-3">
                  <IconDatabase className="size-5 text-desert-tan-light" />
                  <div>
                    <div className="text-lg font-semibold text-text-primary">Local Collections</div>
                    <div className="text-sm text-text-secondary">
                      Maps, ZIM archives, benchmarks, and knowledge files stay on your box.
                    </div>
                  </div>
                </div>
              </div>

              <div className="rounded-[1.35rem] border border-border-default bg-surface-secondary/90 p-4">
                <p className="roachnet-kicker text-[0.68rem] text-text-muted">Privacy</p>
                <div className="mt-2 flex items-center gap-3">
                  <IconShieldLock className="size-5 text-desert-green-light" />
                  <div>
                    <div className="text-lg font-semibold text-text-primary">Local-First Ops</div>
                    <div className="text-sm text-text-secondary">
                      Keep model traffic, content access, and operations close to the machine.
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {items.map((item) => {
            const isEasySetup = item.label === 'Easy Setup'
            const shouldHighlight = isEasySetup && shouldHighlightEasySetup

            return (
              <a key={item.label} href={item.to} target={item.target}>
                <div className="roachnet-card group relative flex h-56 flex-col justify-between overflow-hidden rounded-[1.75rem] border border-border-default p-5 text-left transition-transform duration-200 hover:-translate-y-1">
                  <div className="absolute inset-x-0 top-0 h-px roachnet-divider opacity-70" />
                  {shouldHighlight && (
                    <span className="absolute right-4 top-4 inline-flex items-center rounded-full border border-desert-orange-light/40 bg-desert-orange/20 px-3 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.24em] text-desert-orange-light">
                      Start Here
                    </span>
                  )}
                  <div className="space-y-4">
                    <div className="inline-flex rounded-2xl border border-border-default bg-surface-secondary/80 p-3 text-desert-green-light">
                      {item.icon}
                    </div>
                    <div>
                      <h3 className="text-2xl font-semibold uppercase tracking-[0.09em] text-text-primary">
                        {item.label}
                      </h3>
                      {item.poweredBy && (
                        <p className="mt-1 text-xs uppercase tracking-[0.22em] text-text-muted">
                          Powered by {item.poweredBy}
                        </p>
                      )}
                    </div>
                  </div>
                  <p className="text-sm leading-6 text-text-secondary xl:text-base">
                    {item.description}
                  </p>
                </div>
              </a>
            )
          })}
        </section>
      </div>
    </AppLayout>
  )
}
