import { Head, Link, usePage } from '@inertiajs/react'
import { useEffect, useState, type ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Listbox,
  ListboxButton,
  ListboxOption,
  ListboxOptions,
} from '@headlessui/react'
import { IconCheck, IconChevronDown, IconExternalLink, IconSettings, IconShieldBolt, IconWand } from '@tabler/icons-react'
import Alert from '~/components/Alert'
import StyledButton from '~/components/StyledButton'
import Input from '~/components/inputs/Input'
import SettingsLayout from '~/layouts/SettingsLayout'
import useAIRuntimeStatus from '~/hooks/useAIRuntimeStatus'
import useDebounce from '~/hooks/useDebounce'
import useInternetStatus from '~/hooks/useInternetStatus'
import { useSystemSetting } from '~/hooks/useSystemSetting'
import { useSystemInfo } from '~/hooks/useSystemInfo'
import { useNotifications } from '~/context/NotificationContext'
import api from '~/lib/api'
import type { AIRuntimeProviderName, AIRuntimeStatus } from '../../../types/ai'
import type { KVStoreKey } from '../../../types/kv_store'
import type { InstalledOpenClawSkill, OpenClawSkillSearchResult } from '../../../types/openclaw'
import type { RoachClawStatusResponse } from '../../../types/roachclaw'
import type { SystemInformationResponse } from '../../../types/system'
import { formatModelName, getClawHubRelevanceLabel } from '~/lib/ollama'
import classNames from '~/lib/classNames'

type ProviderCardProps = {
  title: string
  providerLabel: string
  runtimeStatus: AIRuntimeStatus & { loading: boolean }
  configuredValue: string
  onConfiguredValueChange: (value: string) => void
  onSave: () => void
  savePending: boolean
  settingKey: KVStoreKey
  description: string
  helpText: string
  placeholder: string
  icon: ReactNode
  footer?: ReactNode
}

function ProviderCard({
  title,
  providerLabel,
  runtimeStatus,
  configuredValue,
  onConfiguredValueChange,
  onSave,
  savePending,
  settingKey,
  description,
  helpText,
  placeholder,
  icon,
  footer,
}: ProviderCardProps) {
  const statusLabel = runtimeStatus.available ? 'Linked' : runtimeStatus.loading ? 'Checking' : 'Offline'
  const statusClasses = runtimeStatus.available
    ? 'border-desert-green/40 bg-desert-green/15 text-desert-green-light'
    : runtimeStatus.loading
      ? 'border-desert-orange-light/40 bg-desert-orange/15 text-desert-orange-light'
      : 'border-desert-red-light/30 bg-desert-red/15 text-desert-red-light'

  return (
    <section className="roachnet-card rounded-[1.75rem] border border-border-default p-6 md:p-7">
      <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
        <div className="space-y-4">
          <div className="flex items-center gap-4">
            <div className="inline-flex rounded-2xl border border-border-default bg-surface-secondary/80 p-3 text-desert-green-light">
              {icon}
            </div>
            <div>
              <p className="roachnet-kicker text-[0.68rem] text-text-muted">AI Provider</p>
              <h2 className="text-2xl font-semibold uppercase tracking-[0.08em] text-text-primary">
                {title}
              </h2>
            </div>
          </div>

          <p className="max-w-2xl text-sm leading-6 text-text-secondary">{description}</p>

          <div className="grid gap-3 sm:grid-cols-3">
            <div className="rounded-[1.1rem] border border-border-default bg-surface-secondary/70 p-4">
              <p className="roachnet-kicker text-[0.64rem] text-text-muted">Status</p>
              <div className="mt-2">
                <span className={`inline-flex rounded-full border px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] ${statusClasses}`}>
                  {statusLabel}
                </span>
              </div>
            </div>

            <div className="rounded-[1.1rem] border border-border-default bg-surface-secondary/70 p-4">
              <p className="roachnet-kicker text-[0.64rem] text-text-muted">Detected Via</p>
              <p className="mt-2 text-sm font-semibold uppercase tracking-[0.16em] text-text-primary">
                {runtimeStatus.source}
              </p>
            </div>

            <div className="rounded-[1.1rem] border border-border-default bg-surface-secondary/70 p-4">
              <p className="roachnet-kicker text-[0.64rem] text-text-muted">Effective URL</p>
              <p className="mt-2 break-all text-sm text-text-primary">
                {runtimeStatus.baseUrl || 'Not detected'}
              </p>
            </div>
          </div>
        </div>

        <div className="w-full max-w-xl rounded-[1.4rem] border border-border-default bg-surface-secondary/70 p-5">
          <Input
            name={settingKey}
            label={`${providerLabel} Base URL`}
            value={configuredValue}
            onChange={(event) => onConfiguredValueChange(event.target.value)}
            placeholder={placeholder}
            helpText={helpText}
            autoComplete="off"
          />

          <div className="mt-4 flex flex-wrap gap-3">
            <StyledButton onClick={onSave} loading={savePending} icon="IconDeviceFloppy">
              Save Endpoint
            </StyledButton>
            <StyledButton
              variant="ghost"
              onClick={() => onConfiguredValueChange('')}
              disabled={savePending || configuredValue.length === 0}
              icon="IconEraser"
            >
              Clear Override
            </StyledButton>
          </div>

          {runtimeStatus.error && !runtimeStatus.loading && (
            <p className="mt-4 text-sm text-desert-red-light">{runtimeStatus.error}</p>
          )}
        </div>
      </div>

      {footer && <div className="mt-5 border-t border-border-subtle pt-5">{footer}</div>}
    </section>
  )
}

export default function AISettingsPage(props: {
  system: { info: SystemInformationResponse | undefined }
}) {
  const { aiAssistantName } = usePage<{ aiAssistantName: string }>().props
  const { addNotification } = useNotifications()
  const queryClient = useQueryClient()
  const { debounce } = useDebounce()
  const { isOnline } = useInternetStatus()

  const ollamaRuntime = useAIRuntimeStatus('ollama')
  const openClawRuntime = useAIRuntimeStatus('openclaw')
  const { data: systemInfo } = useSystemInfo({ initialData: props.system.info })

  const { data: ollamaBaseUrlSetting } = useSystemSetting({ key: 'ai.ollamaBaseUrl' })
  const { data: openClawBaseUrlSetting } = useSystemSetting({ key: 'ai.openclawBaseUrl' })
  const { data: openClawWorkspacePathSetting } = useSystemSetting({ key: 'ai.openclawWorkspacePath' })

  const [ollamaBaseUrl, setOllamaBaseUrl] = useState('')
  const [openClawBaseUrl, setOpenClawBaseUrl] = useState('')
  const [openClawWorkspacePath, setOpenClawWorkspacePath] = useState('')
  const [skillQueryUI, setSkillQueryUI] = useState('')
  const [skillQuery, setSkillQuery] = useState('')

  useEffect(() => {
    setOllamaBaseUrl(String(ollamaBaseUrlSetting?.value || ''))
  }, [ollamaBaseUrlSetting?.value])

  useEffect(() => {
    setOpenClawBaseUrl(String(openClawBaseUrlSetting?.value || ''))
  }, [openClawBaseUrlSetting?.value])

  useEffect(() => {
    setOpenClawWorkspacePath(String(openClawWorkspacePathSetting?.value || ''))
  }, [openClawWorkspacePathSetting?.value])

  const debouncedSetSkillQuery = debounce((value: string) => {
    setSkillQuery(value.trim())
  }, 350)

  const { data: openClawSkillStatus } = useQuery({
    queryKey: ['openclaw', 'skills', 'status'],
    queryFn: () => api.getOpenClawSkillStatus(),
    staleTime: 30_000,
  })

  const { data: roachClawStatus } = useQuery({
    queryKey: ['roachclaw', 'status'],
    queryFn: () => api.getRoachClawStatus(),
    staleTime: 15_000,
  })

  const { data: installedOpenClawSkills } = useQuery({
    queryKey: ['openclaw', 'skills', 'installed'],
    queryFn: () => api.getInstalledOpenClawSkills(),
    staleTime: 15_000,
  })

  const [roachClawModel, setRoachClawModel] = useState('')

  const roachClawReadiness = (() => {
    if (!roachClawStatus) {
      return {
        label: 'Checking',
        classes: 'border-desert-orange-light/40 bg-desert-orange/15 text-desert-orange-light',
      }
    }

    if (roachClawStatus.ready) {
      return {
        label: 'Ready',
        classes: 'border-desert-green/40 bg-desert-green/15 text-desert-green-light',
      }
    }

    if (roachClawStatus.ollama.available && !roachClawStatus.resolvedDefaultModel) {
      return {
        label: 'Partial',
        classes: 'border-desert-orange-light/40 bg-desert-orange/15 text-desert-orange-light',
      }
    }

    return {
      label: 'Not Configured',
      classes: 'border-desert-red-light/30 bg-desert-red/15 text-desert-red-light',
    }
  })()

  useEffect(() => {
    if (!roachClawStatus) {
      return
    }

    const candidate =
      roachClawStatus.defaultModel ||
      roachClawStatus.installedModels[0] ||
      ''

    if (candidate && candidate !== roachClawModel) {
      setRoachClawModel(candidate)
    }

    if (!openClawWorkspacePath && roachClawStatus.workspacePath) {
      setOpenClawWorkspacePath(roachClawStatus.workspacePath)
    }
  }, [roachClawModel, roachClawStatus, openClawWorkspacePath])

  const { data: openClawSkillSearch, isFetching: searchSkillsPending } = useQuery({
    queryKey: ['openclaw', 'skills', 'search', skillQuery],
    queryFn: () => api.searchOpenClawSkills(skillQuery, 8),
    enabled: isOnline && skillQuery.trim().length >= 2,
    staleTime: 15_000,
  })

  const saveSettingMutation = useMutation({
    mutationFn: async ({ key, value }: { key: KVStoreKey; value: string }) => {
      return await api.updateSetting(key, value.trim())
    },
    onSuccess: async (_, variables) => {
      addNotification({
        type: 'success',
        message: 'AI runtime endpoint saved. Re-checking provider status.',
      })

      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['system-setting', variables.key] }),
        queryClient.invalidateQueries({ queryKey: ['ai-runtime-providers'] }),
        queryClient.invalidateQueries({ queryKey: ['openclaw', 'skills', 'status'] }),
        queryClient.invalidateQueries({ queryKey: ['openclaw', 'skills', 'installed'] }),
      ])
    },
    onError: (error) => {
      console.error('Failed to save AI runtime setting:', error)
      addNotification({
        type: 'error',
        message: 'Failed to save AI runtime setting.',
      })
    },
  })

  const handleSaveProvider = (provider: AIRuntimeProviderName) => {
    if (provider === 'ollama') {
      saveSettingMutation.mutate({
        key: 'ai.ollamaBaseUrl',
        value: ollamaBaseUrl,
      })
      return
    }

    saveSettingMutation.mutate({
      key: 'ai.openclawBaseUrl',
      value: openClawBaseUrl,
    })
  }

  const installOpenClawSkillMutation = useMutation({
    mutationFn: async ({ slug }: { slug: string }) => {
      return await api.installOpenClawSkill(slug)
    },
    onSuccess: async (result) => {
      addNotification({
        type: 'success',
        message: result?.message || 'OpenClaw skill installed successfully.',
      })

      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['openclaw', 'skills', 'installed'] }),
        queryClient.invalidateQueries({ queryKey: ['openclaw', 'skills', 'search'] }),
      ])
    },
    onError: (error) => {
      console.error('Failed to install OpenClaw skill:', error)
      addNotification({
        type: 'error',
        message: 'Failed to install OpenClaw skill.',
      })
    },
  })

  const applyRoachClawMutation = useMutation({
    mutationFn: async () => {
      return api.applyRoachClawOnboarding({
        model: roachClawModel,
        workspacePath: openClawWorkspacePath,
        ollamaBaseUrl,
        openclawBaseUrl,
      })
    },
    onSuccess: async (result) => {
      addNotification({
        type: 'success',
        message: result?.message || 'RoachClaw defaults applied.',
      })

      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['roachclaw', 'status'] }),
        queryClient.invalidateQueries({ queryKey: ['openclaw', 'skills', 'status'] }),
        queryClient.invalidateQueries({ queryKey: ['system-setting', 'ai.roachclawDefaultModel'] }),
      ])
    },
    onError: (error) => {
      console.error('Failed to apply RoachClaw onboarding:', error)
      addNotification({
        type: 'error',
        message: 'Failed to apply RoachClaw onboarding.',
      })
    },
  })

  return (
    <SettingsLayout>
      <Head title="AI Control | RoachNet" />
      <div className="xl:pl-72 w-full">
        <main className="px-6 py-6 lg:px-12 lg:py-8">
          <div className="mb-8 space-y-4">
            <p className="roachnet-kicker text-xs text-desert-green-light">Runtime Control</p>
            <div className="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
              <div className="max-w-4xl space-y-3">
                <h1 className="text-4xl font-semibold uppercase tracking-[0.12em] text-text-primary">
                  AI Control
                </h1>
                <p className="text-base leading-7 text-text-secondary">
                  Link RoachNet to local AI runtimes, override provider endpoints, and manage the
                  shared surface RoachNet uses for local chat, RoachClaw defaults, skills, and
                  connector-ready OpenClaw workflows.
                </p>
              </div>

              <div className="roachnet-card rounded-full px-4 py-2 text-xs uppercase tracking-[0.24em] text-text-secondary">
                Shared AI Surface
              </div>
            </div>
          </div>

          <Alert
            type="info"
            variant="bordered"
            title="Shared runtime control"
            message="Ollama and OpenClaw now sit behind the same runtime status layer. Use this page to stage provider URLs, set the RoachClaw default model, and manage the OpenClaw workspace and skill path without splitting the setup flow across multiple pages."
            className="!mb-8"
          />

          {systemInfo?.hardwareProfile?.isAppleSilicon && (
            <Alert
              type="success"
              variant="bordered"
              title="Apple Silicon Optimization Active"
              message="RoachNet detected Apple Silicon and will prefer native local runtimes. Keep Ollama or OpenClaw on arm64-native loopback endpoints when possible to avoid Docker and Rosetta overhead."
              className="!mb-8"
            />
          )}

          <div className="space-y-6">
            <ProviderCard
              title={aiAssistantName}
              providerLabel="Ollama"
              runtimeStatus={ollamaRuntime}
              configuredValue={ollamaBaseUrl}
              onConfiguredValueChange={setOllamaBaseUrl}
              onSave={() => handleSaveProvider('ollama')}
              savePending={saveSettingMutation.isPending}
              settingKey="ai.ollamaBaseUrl"
              description="RoachNet uses Ollama for local chat, model downloads, and benchmarking. You can point it at a loopback daemon, another local port, or a remote host on your network."
              helpText="Leave this blank to fall back to OLLAMA_BASE_URL, then local discovery on 127.0.0.1:11434, then the managed Docker runtime."
              placeholder="http://127.0.0.1:11434"
              icon={<IconWand className="size-7" />}
              footer={
                <div className="flex flex-wrap items-center gap-3">
                  <Link
                    href="/settings/models"
                    className="inline-flex items-center text-sm font-semibold text-desert-green-light hover:underline"
                  >
                    Open {aiAssistantName} Model Controls
                    <IconExternalLink className="ml-1 size-4" />
                  </Link>
                </div>
              }
            />

            <ProviderCard
              title="OpenClaw"
              providerLabel="OpenClaw"
              runtimeStatus={openClawRuntime}
              configuredValue={openClawBaseUrl}
              onConfiguredValueChange={setOpenClawBaseUrl}
              onSave={() => handleSaveProvider('openclaw')}
              savePending={saveSettingMutation.isPending}
              settingKey="ai.openclawBaseUrl"
              description="OpenClaw is tracked through the same runtime discovery layer as Ollama, so RoachNet can stage agent- and connector-ready defaults without hiding the provider behind a separate setup path."
              helpText="Set the OpenClaw base URL here or provide OPENCLAW_BASE_URL in the environment. RoachNet will probe /health, /api/health, and / to confirm reachability."
              placeholder="http://127.0.0.1:3001"
              icon={<IconShieldBolt className="size-7" />}
              footer={
                <div className="rounded-[1.1rem] border border-border-default bg-surface-secondary/70 p-4">
                  <div className="flex items-start gap-3">
                    <IconSettings className="mt-0.5 size-5 text-desert-orange-light" />
                    <p className="text-sm leading-6 text-text-secondary">
                      The OpenClaw HTTP runtime is optional until you actually launch it. Workspace
                      control, skill search/install, and RoachClaw default-model wiring already use
                      this shared surface today.
                    </p>
                  </div>
                </div>
              }
            />

            <section className="roachnet-card rounded-[1.75rem] border border-border-default p-6 md:p-7">
              <div className="flex flex-col gap-6">
                <div className="space-y-3">
                  <p className="roachnet-kicker text-[0.68rem] text-text-muted">RoachClaw</p>
                  <div className="flex flex-wrap items-center gap-3">
                    <h2 className="text-2xl font-semibold uppercase tracking-[0.08em] text-text-primary">
                      Combined Ollama + OpenClaw Onboarding
                    </h2>
                    <span
                      className={classNames(
                        'inline-flex rounded-full border px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em]',
                        roachClawReadiness.classes
                      )}
                    >
                      {roachClawReadiness.label}
                    </span>
                  </div>
                  <p className="max-w-3xl text-sm leading-6 text-text-secondary">
                    RoachClaw makes Ollama the default local model provider for OpenClaw, keeps
                    the OpenClaw workspace under RoachNet control, and stores the chosen local
                    model as the primary default for the suite.
                  </p>
                  {(roachClawStatus?.preferredModels || []).length > 0 && (
                    <div className="flex flex-wrap gap-2">
                      {roachClawStatus?.preferredModels.map((model) => {
                        const formatted = formatModelName(model)
                        return (
                          <span
                            key={model}
                            className="rounded-full border border-border-default bg-surface-secondary/70 px-3 py-1 text-xs uppercase tracking-[0.16em] text-text-secondary"
                          >
                            {formatted.family}
                            {formatted.size ? ` · ${formatted.size}` : ''}
                          </span>
                        )
                      })}
                    </div>
                  )}
                </div>

                {!roachClawStatus?.cliStatus.openclawAvailable && (
                  <Alert
                    type="warning"
                    variant="bordered"
                    title="OpenClaw CLI not detected"
                    message="RoachClaw can still save the RoachNet-side defaults, but full OpenClaw profile wiring requires the OpenClaw CLI to be installed on this machine."
                  />
                )}

                {(roachClawStatus?.installedModels || []).length === 0 && (
                  <Alert
                    type="info"
                    variant="bordered"
                    title="No local Ollama models detected yet"
                    message="Download at least one local Ollama model, then return here to make it the RoachClaw default."
                  />
                )}

                <div className="grid gap-4 lg:grid-cols-[1fr_1fr]">
                  <div className="rounded-[1.25rem] border border-border-default bg-surface-secondary/70 p-5">
                    <label className="block text-base/6 font-medium text-text-primary">
                      RoachClaw Default Model
                    </label>
                    <p className="mt-1 text-sm text-text-muted">
                      OpenClaw will prefer this local Ollama model as its primary default.
                    </p>
                    <div className="mt-3">
                      <Listbox value={roachClawModel} onChange={setRoachClawModel}>
                        <div className="relative">
                          <ListboxButton className="flex w-full items-center justify-between rounded-xl border border-border-default bg-surface-primary px-4 py-3 text-left">
                            {roachClawModel ? (
                              <div>
                                <div className="text-sm font-semibold uppercase tracking-[0.14em] text-text-primary">
                                  {formatModelName(roachClawModel).family}
                                </div>
                                <div className="mt-1 text-xs text-text-muted">
                                  {formatModelName(roachClawModel).size || roachClawModel}
                                </div>
                              </div>
                            ) : (
                              <span className="text-sm text-text-muted">Select a local model</span>
                            )}
                            <IconChevronDown className="size-4 text-text-muted" />
                          </ListboxButton>
                          <ListboxOptions className="absolute z-20 mt-2 max-h-72 w-full overflow-auto rounded-2xl border border-border-default bg-surface-primary p-2 shadow-xl focus:outline-none">
                            {(roachClawStatus?.installedModels || []).map((model) => {
                              const formatted = formatModelName(model)
                              return (
                                <ListboxOption
                                  key={model}
                                  value={model}
                                  className={({ focus, selected }) =>
                                    classNames(
                                      'mb-1 cursor-pointer rounded-xl border px-3 py-3 transition last:mb-0',
                                      focus || selected
                                        ? 'border-desert-green/40 bg-surface-secondary'
                                        : 'border-transparent hover:border-border-subtle hover:bg-surface-secondary/70'
                                    )
                                  }
                                >
                                  {({ selected }) => (
                                    <div className="flex items-start justify-between gap-3">
                                      <div>
                                        <div className="text-sm font-semibold uppercase tracking-[0.14em] text-text-primary">
                                          {formatted.family}
                                        </div>
                                        <div className="mt-1 text-xs text-text-muted">
                                          {formatted.size || model}
                                        </div>
                                      </div>
                                      {selected && (
                                        <IconCheck className="mt-0.5 size-4 text-desert-green-light" />
                                      )}
                                    </div>
                                  )}
                                </ListboxOption>
                              )
                            })}
                          </ListboxOptions>
                        </div>
                      </Listbox>
                    </div>
                  </div>

                  <div className="rounded-[1.25rem] border border-border-default bg-surface-secondary/70 p-5">
                    <p className="roachnet-kicker text-[0.64rem] text-text-muted">Current Profile</p>
                    <div className="mt-3 space-y-2 text-sm text-text-secondary">
                      <p>
                        Workspace: <span className="text-text-primary">{roachClawStatus?.workspacePath || openClawWorkspacePath || 'Not set'}</span>
                      </p>
                      <p>
                        Default model:{' '}
                        <span className="text-text-primary">
                          {roachClawStatus?.defaultModel
                            ? `${formatModelName(roachClawStatus.defaultModel).family}${formatModelName(roachClawStatus.defaultModel).size ? ` · ${formatModelName(roachClawStatus.defaultModel).size}` : ''}`
                            : 'Not set'}
                        </span>
                      </p>
                      <p>
                        OpenClaw config: <span className="text-text-primary break-all">{roachClawStatus?.configFilePath || 'Unavailable'}</span>
                      </p>
                    </div>
                  </div>
                </div>

                <div className="flex flex-wrap gap-3">
                  <StyledButton
                    onClick={() => applyRoachClawMutation.mutate()}
                    loading={applyRoachClawMutation.isPending}
                    disabled={!roachClawModel}
                    icon="IconWand"
                  >
                    Apply RoachClaw Defaults
                  </StyledButton>
                  <Link
                    href="/settings/models"
                    className="inline-flex items-center text-sm font-semibold text-desert-green-light hover:underline"
                  >
                    Manage Ollama Models
                    <IconExternalLink className="ml-1 size-4" />
                  </Link>
                </div>
              </div>
            </section>

            <section className="roachnet-card rounded-[1.75rem] border border-border-default p-6 md:p-7">
              <div className="flex flex-col gap-6">
                <div className="space-y-3">
                  <p className="roachnet-kicker text-[0.68rem] text-text-muted">OpenClaw Skills</p>
                  <h2 className="text-2xl font-semibold uppercase tracking-[0.08em] text-text-primary">
                    ClawHub Skill Browser
                  </h2>
                  <p className="max-w-3xl text-sm leading-6 text-text-secondary">
                    Browse ClawHub when the machine is online, install skills into a local
                    OpenClaw workspace, and keep the workspace path under RoachNet control.
                    Treat third-party skills as untrusted code and review them before enabling.
                  </p>
                </div>

                {!isOnline && (
                  <Alert
                    type="warning"
                    variant="bordered"
                    title="Internet connection required for ClawHub browsing"
                    message="ClawHub search and install requires an internet connection. Installed skills already present in the configured workspace are still listed below."
                  />
                )}

                {!openClawSkillStatus?.clawhubAvailable && (
                  <Alert
                    type="warning"
                    variant="bordered"
                    title="ClawHub CLI not available"
                    message="RoachNet uses the official ClawHub CLI for search and install. Ensure Node.js/npm is installed or install the clawhub CLI directly on this machine."
                  />
                )}

                <div className="grid gap-4 lg:grid-cols-[1.2fr_0.8fr]">
                  <div className="rounded-[1.25rem] border border-border-default bg-surface-secondary/70 p-5">
                    <Input
                      name="ai.openclawWorkspacePath"
                      label="OpenClaw Workspace Path"
                      value={openClawWorkspacePath}
                      onChange={(event) => setOpenClawWorkspacePath(event.target.value)}
                      placeholder={openClawSkillStatus?.workspacePath || '/path/to/openclaw-workspace'}
                      helpText="Skills are installed into <workspace>/skills using the official ClawHub CLI."
                    />

                    <div className="mt-4 flex flex-wrap gap-3">
                      <StyledButton
                        onClick={() =>
                          saveSettingMutation.mutate({
                            key: 'ai.openclawWorkspacePath',
                            value: openClawWorkspacePath,
                          })
                        }
                        loading={saveSettingMutation.isPending}
                        icon="IconDeviceFloppy"
                      >
                        Save Workspace
                      </StyledButton>
                      {openClawSkillStatus?.workspacePath && (
                        <div className="rounded-full border border-border-default bg-surface-primary/80 px-4 py-2 text-xs uppercase tracking-[0.18em] text-text-secondary">
                          Effective: {openClawSkillStatus.workspacePath}
                        </div>
                      )}
                    </div>
                  </div>

                  <div className="rounded-[1.25rem] border border-border-default bg-surface-secondary/70 p-5">
                    <p className="roachnet-kicker text-[0.64rem] text-text-muted">Installed Skills</p>
                    <div className="mt-3 space-y-3">
                      {(installedOpenClawSkills?.skills || []).length === 0 && (
                        <p className="text-sm text-text-secondary">
                          No OpenClaw skills are installed in the configured workspace yet.
                        </p>
                      )}
                      {(installedOpenClawSkills?.skills || []).map((skill: InstalledOpenClawSkill) => (
                        <div
                          key={skill.slug}
                          className="rounded-[1rem] border border-border-default bg-surface-primary/80 p-4"
                        >
                          <div className="flex items-start justify-between gap-3">
                            <div>
                              <p className="text-sm font-semibold uppercase tracking-[0.14em] text-text-primary">
                                {skill.name}
                              </p>
                              <p className="mt-1 text-xs uppercase tracking-[0.14em] text-desert-green-light">
                                {skill.slug}
                              </p>
                            </div>
                          </div>
                          {skill.description && (
                            <p className="mt-2 text-sm leading-6 text-text-secondary">{skill.description}</p>
                          )}
                          <p className="mt-2 break-all text-xs text-text-muted">{skill.path}</p>
                        </div>
                      ))}
                    </div>
                  </div>
                </div>

                <div className="rounded-[1.25rem] border border-border-default bg-surface-secondary/70 p-5">
                  <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
                    <Input
                      name="clawhubSearch"
                      label="Search ClawHub"
                      value={skillQueryUI}
                      onChange={(event) => {
                        setSkillQueryUI(event.target.value)
                        debouncedSetSkillQuery(event.target.value)
                      }}
                      placeholder="Search by workflow or skill slug"
                      helpText="RoachNet queries the official ClawHub CLI when you are online."
                      containerClassName="w-full"
                    />
                    <div className="rounded-full border border-border-default bg-surface-primary/80 px-4 py-2 text-xs uppercase tracking-[0.18em] text-text-secondary">
                      {skillQuery.trim().length < 2
                        ? 'Start typing to search (min 2 chars)'
                        : searchSkillsPending
                          ? 'Searching'
                          : 'Results update as you type'}
                    </div>
                  </div>

                  <div className="mt-5 grid gap-3 md:grid-cols-2">
                    {(openClawSkillSearch?.skills || []).map((skill: OpenClawSkillSearchResult) => (
                      <div
                        key={skill.slug}
                        className="rounded-[1rem] border border-border-default bg-surface-primary/80 p-4"
                      >
                        <div className="flex items-start justify-between gap-4">
                          <div>
                            <p className="text-sm font-semibold uppercase tracking-[0.14em] text-text-primary">
                              {skill.title}
                            </p>
                            <p className="mt-1 text-xs uppercase tracking-[0.14em] text-desert-green-light">
                              {skill.slug}
                            </p>
                            <p className="mt-2 text-xs uppercase tracking-[0.14em] text-text-muted">
                              {getClawHubRelevanceLabel(skill.score)}
                            </p>
                          </div>
                          <StyledButton
                            size="sm"
                            icon="IconDownload"
                            loading={installOpenClawSkillMutation.isPending}
                            disabled={!isOnline || !openClawSkillStatus?.clawhubAvailable}
                            onClick={() => installOpenClawSkillMutation.mutate({ slug: skill.slug })}
                          >
                            Install
                          </StyledButton>
                        </div>
                      </div>
                    ))}
                  </div>

                  {skillQuery.trim().length >= 2 && !searchSkillsPending && (openClawSkillSearch?.skills || []).length === 0 && (
                    <p className="mt-4 text-sm text-text-secondary">
                      No ClawHub skills matched that search.
                    </p>
                  )}

                  <div className="mt-5 flex flex-wrap items-center gap-3">
                    <a
                      href="https://clawhub.com"
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center text-sm font-semibold text-desert-green-light hover:underline"
                    >
                      Open ClawHub
                      <IconExternalLink className="ml-1 size-4" />
                    </a>
                    <div className="rounded-full border border-border-default bg-surface-primary/80 px-4 py-2 text-xs uppercase tracking-[0.18em] text-text-secondary">
                      Runner: {openClawSkillStatus?.runner || 'unknown'}
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </main>
      </div>
    </SettingsLayout>
  )
}
