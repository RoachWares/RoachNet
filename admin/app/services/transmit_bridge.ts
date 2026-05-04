import logger from '@adonisjs/core/services/logger'

export async function broadcastTransmit(channel: string, payload: unknown): Promise<void> {
  if (process.env.ROACHNET_DISABLE_TRANSMIT === '1') {
    return
  }

  try {
    const { default: transmit } = await import('@adonisjs/transmit/services/main')
    await transmit.broadcast(channel, payload as any)
  } catch (error) {
    logger.warn(
      `[TransmitBridge] Skipping broadcast for ${channel}: ${error instanceof Error ? error.message : String(error)}`
    )
  }
}
