export function formatModelName(model: string): { family: string; size: string | null; tag: string | null } {
  const [baseName, rawTag] = model.split(':')
  const tag = rawTag || null
  const sizeMatch = rawTag?.match(/(\d+(?:\.\d+)?)b/i)
  const size = sizeMatch ? `${sizeMatch[1].toUpperCase()}B` : null

  const family = baseName
    .split(/[-_.]/)
    .filter(Boolean)
    .map((segment) =>
      segment
        .replace(/(\d+)/g, ' $1')
        .trim()
        .split(/\s+/)
        .map((part) => {
          if (/^\d+(\.\d+)?$/.test(part)) {
            return part
          }

          return part.charAt(0).toUpperCase() + part.slice(1)
        })
        .join(' ')
    )
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim()

  return {
    family: family || model,
    size,
    tag,
  }
}

export function getModelThinkingIndicator(model: string): boolean {
  const normalized = model.toLowerCase()
  return (
    normalized.includes('deepseek-r1') ||
    normalized.includes('thinking') ||
    normalized.startsWith('gpt-oss')
  )
}

export function getClawHubRelevanceLabel(score: number | null): string {
  if (score === null) {
    return 'Related'
  }

  if (score >= 0.7) {
    return 'Best Match'
  }

  if (score >= 0.45) {
    return 'Strong Match'
  }

  return 'Related'
}
