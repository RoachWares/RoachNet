function positiveInteger(value, fallback) {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback
}

export function createAsyncTTLCache(loader, options = {}) {
  if (typeof loader !== 'function') {
    throw new TypeError('Async TTL cache requires a loader function.')
  }

  const ttlMs = positiveInteger(options.ttlMs, 1_000)
  const now = typeof options.now === 'function' ? options.now : Date.now
  const entries = new Map()

  async function get(key, ...loaderArguments) {
    const cached = entries.get(key)
    const currentTime = now()

    if (cached?.hasValue && cached.expiresAt > currentTime) {
      return cached.value
    }
    if (cached?.pending) {
      return cached.pending
    }

    const pending = Promise.resolve().then(() => loader(key, ...loaderArguments))
    entries.set(key, { pending })

    try {
      const value = await pending
      if (entries.get(key)?.pending === pending) {
        entries.set(key, {
          hasValue: true,
          value,
          expiresAt: now() + ttlMs,
        })
      }
      return value
    } catch (error) {
      if (entries.get(key)?.pending === pending) {
        entries.delete(key)
      }
      throw error
    }
  }

  function invalidate(key) {
    entries.delete(key)
  }

  function clear() {
    entries.clear()
  }

  return { get, invalidate, clear }
}
