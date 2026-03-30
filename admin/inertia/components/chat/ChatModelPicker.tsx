import {
  Listbox,
  ListboxButton,
  ListboxOption,
  ListboxOptions,
} from '@headlessui/react'
import { IconBrain, IconCheck, IconChevronDown } from '@tabler/icons-react'
import { formatBytes } from '~/lib/util'
import { formatModelName, getModelThinkingIndicator } from '~/lib/ollama'
import classNames from '~/lib/classNames'

interface ChatModelPickerProps {
  models: Array<{ name: string; size: number }>
  selectedModel: string
  onChange: (value: string) => void
}

export default function ChatModelPicker({
  models,
  selectedModel,
  onChange,
}: ChatModelPickerProps) {
  const activeModel = models.find((model) => model.name === selectedModel) || models[0]
  const activeDetails = activeModel ? formatModelName(activeModel.name) : null

  return (
    <Listbox value={selectedModel} onChange={onChange}>
      <div className="relative min-w-[18rem]">
        <ListboxButton className="flex w-full items-center justify-between rounded-2xl border border-border-default bg-surface-primary/90 px-4 py-2.5 text-left shadow-sm transition hover:border-desert-green/50 focus:outline-none focus:ring-2 focus:ring-desert-green">
          <div className="min-w-0">
            <div className="truncate text-sm font-semibold uppercase tracking-[0.16em] text-text-primary">
              {activeDetails?.family || 'Select Model'}
            </div>
            <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-text-muted">
              {activeDetails?.size && (
                <span className="rounded-full border border-border-subtle bg-surface-secondary px-2 py-1 uppercase tracking-[0.16em]">
                  {activeDetails.size}
                </span>
              )}
              {activeModel && (
                <span className="rounded-full border border-border-subtle bg-surface-secondary px-2 py-1">
                  {formatBytes(activeModel.size)}
                </span>
              )}
              {activeModel && getModelThinkingIndicator(activeModel.name) && (
                <span className="inline-flex items-center gap-1 rounded-full border border-desert-orange-light/30 bg-desert-orange/10 px-2 py-1 text-desert-orange-light">
                  <IconBrain className="size-3.5" />
                  Thinking
                </span>
              )}
            </div>
          </div>
          <IconChevronDown className="ml-3 size-5 shrink-0 text-text-muted" />
        </ListboxButton>

        <ListboxOptions className="absolute right-0 z-20 mt-2 max-h-80 w-full overflow-auto rounded-2xl border border-border-default bg-surface-primary p-2 shadow-2xl focus:outline-none">
          {models.map((model) => {
            const details = formatModelName(model.name)
            const supportsThinking = getModelThinkingIndicator(model.name)

            return (
              <ListboxOption
                key={model.name}
                value={model.name}
                className={({ focus, selected }) =>
                  classNames(
                    'mb-1 cursor-pointer rounded-2xl border px-3 py-3 transition last:mb-0',
                    focus || selected
                      ? 'border-desert-green/40 bg-surface-secondary'
                      : 'border-transparent bg-transparent hover:border-border-subtle hover:bg-surface-secondary/70'
                  )
                }
              >
                {({ selected }) => (
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate text-sm font-semibold uppercase tracking-[0.14em] text-text-primary">
                        {details.family}
                      </div>
                      <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-text-muted">
                        {details.size && (
                          <span className="rounded-full border border-border-subtle bg-surface-primary px-2 py-1 uppercase tracking-[0.16em]">
                            {details.size}
                          </span>
                        )}
                        <span className="rounded-full border border-border-subtle bg-surface-primary px-2 py-1">
                          {formatBytes(model.size)}
                        </span>
                        {supportsThinking && (
                          <span className="inline-flex items-center gap-1 rounded-full border border-desert-orange-light/30 bg-desert-orange/10 px-2 py-1 text-desert-orange-light">
                            <IconBrain className="size-3.5" />
                            Thinking
                          </span>
                        )}
                      </div>
                      <div className="mt-2 truncate text-xs text-text-muted">{model.name}</div>
                    </div>
                    {selected && <IconCheck className="mt-0.5 size-4 shrink-0 text-desert-green-light" />}
                  </div>
                )}
              </ListboxOption>
            )
          })}
        </ListboxOptions>
      </div>
    </Listbox>
  )
}
