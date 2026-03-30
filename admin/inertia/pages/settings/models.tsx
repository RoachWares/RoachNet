import { Head, router, usePage } from '@inertiajs/react'
import { useEffect, useRef, useState } from 'react'
import StyledTable from '~/components/StyledTable'
import SettingsLayout from '~/layouts/SettingsLayout'
import { NomadOllamaModel } from '../../../types/ollama'
import StyledButton from '~/components/StyledButton'
import Alert from '~/components/Alert'
import { useNotifications } from '~/context/NotificationContext'
import api from '~/lib/api'
import { useModals } from '~/context/ModalContext'
import StyledModal from '~/components/StyledModal'
import { ModelResponse } from 'ollama'
import Switch from '~/components/inputs/Switch'
import StyledSectionHeader from '~/components/StyledSectionHeader'
import { useMutation, useQuery } from '@tanstack/react-query'
import Input from '~/components/inputs/Input'
import { IconSearch } from '@tabler/icons-react'
import useDebounce from '~/hooks/useDebounce'
import ActiveModelDownloads from '~/components/ActiveModelDownloads'
import { useSystemInfo } from '~/hooks/useSystemInfo'
import type { AIRuntimeStatus } from '../../../types/ai'

const GPU_BANNER_STORAGE_KEY = 'roachnet:gpu-banner-dismissed'
const LEGACY_GPU_BANNER_STORAGE_KEY = 'nomad:gpu-banner-dismissed'

export default function ModelsPage(props: {
  models: {
    availableModels: NomadOllamaModel[]
    installedModels: ModelResponse[]
    runtimeStatus: AIRuntimeStatus
    settings: { chatSuggestionsEnabled: boolean; aiAssistantCustomName: string }
  }
}) {
  const { aiAssistantName } = usePage<{ aiAssistantName: string }>().props
  const { addNotification } = useNotifications()
  const { openModal, closeAllModals } = useModals()
  const { debounce } = useDebounce()
  const { data: systemInfo } = useSystemInfo({})
  const runtimeStatus = props.models.runtimeStatus
  const installedModelNames = props.models.installedModels.map((model) => model.name)

  const [gpuBannerDismissed, setGpuBannerDismissed] = useState(() => {
    try {
      return (
        localStorage.getItem(GPU_BANNER_STORAGE_KEY) === 'true' ||
        localStorage.getItem(LEGACY_GPU_BANNER_STORAGE_KEY) === 'true'
      )
    } catch {
      return false
    }
  })
  const [reinstalling, setReinstalling] = useState(false)

  const handleDismissGpuBanner = () => {
    setGpuBannerDismissed(true)
    try {
      localStorage.setItem(GPU_BANNER_STORAGE_KEY, 'true')
    } catch {}
  }

  const handleForceReinstallOllama = () => {
    openModal(
      <StyledModal
        title="Reinstall AI Assistant?"
        onConfirm={async () => {
          closeAllModals()
          setReinstalling(true)
          try {
            const response = await api.forceReinstallService('nomad_ollama')
            if (!response || !response.success) {
              throw new Error(response?.message || 'Force reinstall failed')
            }
            addNotification({
              message: `${aiAssistantName} is being reinstalled with GPU support. This page will reload shortly.`,
              type: 'success',
            })
            try {
              localStorage.removeItem(GPU_BANNER_STORAGE_KEY)
              localStorage.removeItem(LEGACY_GPU_BANNER_STORAGE_KEY)
            } catch {}
            setTimeout(() => window.location.reload(), 5000)
          } catch (error) {
            addNotification({
              message: `Failed to reinstall: ${error instanceof Error ? error.message : 'Unknown error'}`,
              type: 'error',
            })
            setReinstalling(false)
          }
        }}
        onCancel={closeAllModals}
        open={true}
        confirmText="Reinstall"
        cancelText="Cancel"
      >
        <p className="text-text-primary">
          This will recreate the {aiAssistantName} container with GPU support enabled.
          Your downloaded models will be preserved. The service will be briefly
          unavailable during reinstall.
        </p>
      </StyledModal>,
      'gpu-health-force-reinstall-modal'
    )
  }
  const [chatSuggestionsEnabled, setChatSuggestionsEnabled] = useState(
    props.models.settings.chatSuggestionsEnabled
  )
  const [aiAssistantCustomName, setAiAssistantCustomName] = useState(
    props.models.settings.aiAssistantCustomName
  )

  const [query, setQuery] = useState('')
  const [queryUI, setQueryUI] = useState('')
  const [limit, setLimit] = useState(15)
  const [testModel, setTestModel] = useState(installedModelNames[0] || '')
  const [testPrompt, setTestPrompt] = useState(
    'Give me a short RoachNet runtime readiness check in one paragraph.'
  )
  const [testOutput, setTestOutput] = useState('')

  const debouncedSetQuery = debounce((val: string) => {
    setQuery(val)
  }, 300)

  const forceRefreshRef = useRef(false)
  const [isForceRefreshing, setIsForceRefreshing] = useState(false)

  useEffect(() => {
    if (!installedModelNames.includes(testModel)) {
      setTestModel(installedModelNames[0] || '')
    }
  }, [installedModelNames, testModel])

  const { data: availableModelData, isFetching, refetch } = useQuery({
    queryKey: ['ollama', 'availableModels', query, limit],
    queryFn: async () => {
      const force = forceRefreshRef.current
      forceRefreshRef.current = false
      const res = await api.getAvailableModels({
        query,
        recommendedOnly: false,
        limit,
        force: force || undefined,
      })
      if (!res) {
        return {
          models: [],
          hasMore: false,
        }
      }
      return res
    },
    initialData: { models: props.models.availableModels, hasMore: false },
  })

  async function handleForceRefresh() {
    forceRefreshRef.current = true
    setIsForceRefreshing(true)
    await refetch()
    setIsForceRefreshing(false)
    addNotification({ message: 'Model list refreshed from remote.', type: 'success' })
  }

  async function handleInstallModel(modelName: string) {
    try {
      const res = await api.downloadModel(modelName)
      if (res.success) {
        addNotification({
          message: `Model download initiated for ${modelName}. It may take some time to complete.`,
          type: 'success',
        })
      }
    } catch (error) {
      console.error('Error installing model:', error)
      addNotification({
        message: `There was an error installing the model: ${modelName}. Please try again.`,
        type: 'error',
      })
    }
  }

  async function handleDeleteModel(modelName: string) {
    try {
      const res = await api.deleteModel(modelName)
      if (res.success) {
        addNotification({
          message: `Model deleted: ${modelName}.`,
          type: 'success',
        })
      }
      closeAllModals()
      router.reload()
    } catch (error) {
      console.error('Error deleting model:', error)
      addNotification({
        message: `There was an error deleting the model: ${modelName}. Please try again.`,
        type: 'error',
      })
    }
  }

  async function confirmDeleteModel(model: string) {
    openModal(
      <StyledModal
        title="Delete Model?"
        onConfirm={() => {
          handleDeleteModel(model)
        }}
        onCancel={closeAllModals}
        open={true}
        confirmText="Delete"
        cancelText="Cancel"
        confirmVariant="primary"
      >
        <p className="text-text-primary">
          Are you sure you want to delete this model? You will need to download it again if you want
          to use it in the future.
        </p>
      </StyledModal>,
      'confirm-delete-model-modal'
    )
  }

  const updateSettingMutation = useMutation({
    mutationFn: async ({ key, value }: { key: string; value: boolean | string }) => {
      return await api.updateSetting(key, value)
    },
    onSuccess: () => {
      addNotification({
        message: 'Setting updated successfully.',
        type: 'success',
      })
    },
    onError: (error) => {
      console.error('Error updating setting:', error)
      addNotification({
        message: 'There was an error updating the setting. Please try again.',
        type: 'error',
      })
    },
  })

  const runModelCheckMutation = useMutation({
    mutationFn: async ({ model, prompt }: { model: string; prompt: string }) => {
      const response = await api.sendChatMessage({
        model,
        messages: [{ role: 'user', content: prompt }],
      })

      if (!response?.message?.content) {
        throw new Error('No response returned from the selected Ollama model.')
      }

      return response
    },
    onSuccess: (response) => {
      setTestOutput(response.message.content)
      addNotification({
        message: `Model check completed with ${response.model}.`,
        type: 'success',
      })
    },
    onError: (error) => {
      console.error('Error running Ollama model check:', error)
      addNotification({
        message: error instanceof Error ? error.message : 'Failed to run model check.',
        type: 'error',
      })
    },
  })

  return (
    <SettingsLayout>
      <Head title={`${aiAssistantName} Settings | RoachNet`} />
      <div className="xl:pl-72 w-full">
        <main className="px-12 py-6">
          <h1 className="text-4xl font-semibold mb-4">{aiAssistantName}</h1>
          <p className="text-text-muted mb-4">
            Easily manage the {aiAssistantName}'s settings and installed models. We recommend
            starting with smaller models first to see how they perform on your system before moving
            on to larger ones.
          </p>
          {!runtimeStatus.available && (
            <Alert
              title={`${aiAssistantName} is not available.`}
              message={`Start Ollama locally on ${runtimeStatus.baseUrl || 'http://127.0.0.1:11434'}, set OLLAMA_BASE_URL, or install the managed service to manage models from this page.`}
              type="warning"
              variant="solid"
              className="!mt-6"
            />
          )}
          {runtimeStatus.available && runtimeStatus.source !== 'docker' && runtimeStatus.baseUrl && (
            <Alert
              type="info"
              variant="bordered"
              title="Using External Ollama Runtime"
              message={`${aiAssistantName} is connected to ${runtimeStatus.baseUrl}. Docker-specific reinstall and GPU passthrough controls do not apply in this mode.`}
              className="!mt-6"
            />
          )}
          {runtimeStatus.available && runtimeStatus.source === 'docker' && systemInfo?.gpuHealth?.status === 'passthrough_failed' && !gpuBannerDismissed && (
            <Alert
              type="warning"
              variant="bordered"
              title="GPU Not Accessible"
              message={`Your system has an NVIDIA GPU, but ${aiAssistantName} can't access it. AI is running on CPU only, which is significantly slower.`}
              className="!mt-6"
              dismissible={true}
              onDismiss={handleDismissGpuBanner}
              buttonProps={{
                children: `Fix: Reinstall ${aiAssistantName}`,
                icon: 'IconRefresh',
                variant: 'action',
                size: 'sm',
                onClick: handleForceReinstallOllama,
                loading: reinstalling,
                disabled: reinstalling,
              }}
            />
          )}

          <StyledSectionHeader title="Settings" className="mt-8 mb-4" />
          <div className="bg-surface-primary rounded-lg border-2 border-border-subtle p-6">
            <div className="space-y-4">
              <Switch
                checked={chatSuggestionsEnabled}
                onChange={(newVal) => {
                  setChatSuggestionsEnabled(newVal)
                  updateSettingMutation.mutate({ key: 'chat.suggestionsEnabled', value: newVal })
                }}
                label="Chat Suggestions"
                description="Display AI-generated conversation starters in the chat interface"
              />
              <Input
                name="aiAssistantCustomName"
                label="Assistant Name"
                helpText='Give your AI assistant a custom name that will be used in the chat interface and other areas of the application.'
                placeholder="AI Assistant"
                value={aiAssistantCustomName}
                onChange={(e) => setAiAssistantCustomName(e.target.value)}
                onBlur={() =>
                  updateSettingMutation.mutate({
                    key: 'ai.assistantCustomName',
                    value: aiAssistantCustomName,
                  })
                }
              />
            </div>
          </div>
          <ActiveModelDownloads withHeader />

          <StyledSectionHeader title="Model Runtime Check" className="mt-12 mb-4" />
          <div className="bg-surface-primary rounded-lg border-2 border-border-subtle p-6">
            <div className="flex flex-col gap-6">
              <div className="space-y-2">
                <p className="text-text-primary font-semibold">
                  Run a quick prompt against any installed Ollama model.
                </p>
                <p className="text-sm text-text-muted">
                  This confirms the selected model is downloaded, reachable, and responding on the
                  configured runtime endpoint.
                </p>
                <p className="text-xs uppercase tracking-[0.18em] text-text-muted">
                  Runtime source: {runtimeStatus.source} {runtimeStatus.baseUrl ? `• ${runtimeStatus.baseUrl}` : ''}
                </p>
              </div>

              {installedModelNames.length === 0 ? (
                <Alert
                  type="warning"
                  variant="bordered"
                  title="No Installed Models Yet"
                  message="Install at least one Ollama model below, then return here to run a live prompt against it."
                />
              ) : (
                <div className="grid gap-5 xl:grid-cols-[0.9fr_1.1fr]">
                  <div className="space-y-4">
                    <div>
                      <label
                        htmlFor="testModel"
                        className="block text-base/6 font-medium text-text-primary"
                      >
                        Installed Model
                      </label>
                      <div className="mt-1.5">
                        <select
                          id="testModel"
                          name="testModel"
                          value={testModel}
                          onChange={(event) => setTestModel(event.target.value)}
                          className="block w-full rounded-md bg-surface-primary px-3 py-2 text-base text-text-primary border border-border-default focus:outline focus:outline-2 focus:-outline-offset-2 focus:outline-primary sm:text-sm/6"
                        >
                          {installedModelNames.map((modelName) => (
                            <option key={modelName} value={modelName}>
                              {modelName}
                            </option>
                          ))}
                        </select>
                      </div>
                    </div>

                    <div>
                      <label
                        htmlFor="testPrompt"
                        className="block text-base/6 font-medium text-text-primary"
                      >
                        Test Prompt
                      </label>
                      <p className="mt-1 text-sm text-text-muted">
                        Keep this short. RoachNet uses a normal chat call here, so this is a real
                        runtime test, not a mock ping.
                      </p>
                      <textarea
                        id="testPrompt"
                        name="testPrompt"
                        value={testPrompt}
                        onChange={(event) => setTestPrompt(event.target.value)}
                        rows={6}
                        className="mt-1.5 block w-full rounded-md bg-surface-primary px-3 py-2 text-base text-text-primary border border-border-default placeholder:text-text-muted focus:outline focus:outline-2 focus:-outline-offset-2 focus:outline-primary sm:text-sm/6"
                      />
                    </div>

                    <div className="flex flex-wrap gap-3">
                      <StyledButton
                        onClick={() =>
                          runModelCheckMutation.mutate({
                            model: testModel,
                            prompt: testPrompt.trim(),
                          })
                        }
                        loading={runModelCheckMutation.isPending}
                        disabled={!runtimeStatus.available || !testModel || testPrompt.trim().length === 0}
                        icon="IconPlayerPlay"
                      >
                        Run Prompt
                      </StyledButton>
                      <StyledButton
                        variant="ghost"
                        onClick={() => setTestOutput('')}
                        disabled={!testOutput}
                        icon="IconEraser"
                      >
                        Clear Output
                      </StyledButton>
                    </div>
                  </div>

                  <div className="rounded-xl border border-border-default bg-surface-secondary/60 p-4">
                    <p className="text-xs uppercase tracking-[0.18em] text-text-muted">
                      Model Output
                    </p>
                    <div className="mt-3 min-h-48 rounded-lg border border-border-subtle bg-surface-primary/80 p-4 text-sm leading-6 text-text-secondary whitespace-pre-wrap">
                      {runModelCheckMutation.isPending
                        ? `Running ${testModel}...`
                        : testOutput || 'Run a prompt to verify the selected Ollama model.'}
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>

          <StyledSectionHeader title="Models" className="mt-12 mb-4" />
          <div className="flex justify-start items-center gap-3 mt-4">
            <Input
              name="search"
              label=""
              placeholder="Search language models.."
              value={queryUI}
              onChange={(e) => {
                setQueryUI(e.target.value)
                debouncedSetQuery(e.target.value)
              }}
              className="w-1/3"
              leftIcon={<IconSearch className="w-5 h-5 text-text-muted" />}
            />
            <StyledButton
              variant="secondary"
              onClick={handleForceRefresh}
              icon="IconRefresh"
              loading={isForceRefreshing}
              className='mt-1'
            >
              Refresh Models
            </StyledButton>
          </div>
          <StyledTable<NomadOllamaModel>
            className="font-semibold mt-4"
            rowLines={true}
            columns={[
              {
                accessor: 'name',
                title: 'Name',
                render(record) {
                  return (
                    <div className="flex flex-col">
                      <p className="text-lg font-semibold">{record.name}</p>
                      <p className="text-sm text-text-muted">{record.description}</p>
                    </div>
                  )
                },
              },
              {
                accessor: 'estimated_pulls',
                title: 'Estimated Pulls',
              },
              {
                accessor: 'model_last_updated',
                title: 'Last Updated',
              },
            ]}
            data={availableModelData?.models || []}
            loading={isFetching}
            expandable={{
              expandedRowRender: (record) => (
                <div className="pl-14">
                  <div className="bg-surface-primary overflow-hidden">
                    <table className="min-w-full divide-y divide-border-subtle">
                      <thead className="bg-surface-primary">
                        <tr>
                          <th className="px-6 py-3 text-left text-xs font-medium text-text-muted uppercase tracking-wider">
                            Tag
                          </th>
                          <th className="px-6 py-3 text-left text-xs font-medium text-text-muted uppercase tracking-wider">
                            Input Type
                          </th>
                          <th className="px-6 py-3 text-left text-xs font-medium text-text-muted uppercase tracking-wider">
                            Context Size
                          </th>
                          <th className="px-6 py-3 text-left text-xs font-medium text-text-muted uppercase tracking-wider">
                            Model Size
                          </th>
                          <th className="px-6 py-3 text-left text-xs font-medium text-text-muted uppercase tracking-wider">
                            Action
                          </th>
                        </tr>
                      </thead>
                      <tbody className="bg-surface-primary divide-y divide-border-subtle">
                        {record.tags.map((tag, tagIndex) => {
                          const isInstalled = props.models.installedModels.some(
                            (mod) => mod.name === tag.name
                          )
                          return (
                            <tr key={tagIndex} className="hover:bg-surface-secondary">
                              <td className="px-6 py-4 whitespace-nowrap">
                                <span className="text-sm font-medium text-text-primary">
                                  {tag.name}
                                </span>
                              </td>
                              <td className="px-6 py-4 whitespace-nowrap">
                                <span className="text-sm text-text-secondary">{tag.input || 'N/A'}</span>
                              </td>
                              <td className="px-6 py-4 whitespace-nowrap">
                                <span className="text-sm text-text-secondary">
                                  {tag.context || 'N/A'}
                                </span>
                              </td>
                              <td className="px-6 py-4 whitespace-nowrap">
                                <span className="text-sm text-text-secondary">{tag.size || 'N/A'}</span>
                              </td>
                              <td className="px-6 py-4 whitespace-nowrap">
                                <StyledButton
                                  variant={isInstalled ? 'danger' : 'primary'}
                                  onClick={() => {
                                    if (!runtimeStatus.available) {
                                      addNotification({
                                        message: `${aiAssistantName} is not available. Start Ollama or install the managed service first.`,
                                        type: 'error',
                                      })
                                      return
                                    }
                                    if (!isInstalled) {
                                      handleInstallModel(tag.name)
                                    } else {
                                      confirmDeleteModel(tag.name)
                                    }
                                  }}
                                  icon={isInstalled ? 'IconTrash' : 'IconDownload'}
                                  disabled={!runtimeStatus.available}
                                  title={
                                    !runtimeStatus.available
                                      ? `${aiAssistantName} must be running to manage models`
                                      : undefined
                                  }
                                >
                                  {isInstalled ? 'Delete' : 'Install'}
                                </StyledButton>
                              </td>
                            </tr>
                          )
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>
              ),
            }}
          />
          <div className="flex justify-center mt-6">
            {availableModelData?.hasMore && (
              <StyledButton
                variant="primary"
                onClick={() => {
                  setLimit((prev) => prev + 15)
                }}
              >
                Load More
              </StyledButton>
            )}
          </div>
        </main>
      </div>
    </SettingsLayout>
  )
}
