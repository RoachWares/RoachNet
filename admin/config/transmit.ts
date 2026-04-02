import env from '#start/env'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] transmit')
}

const transmitDisabled = process.env.ROACHNET_DISABLE_TRANSMIT === '1'

const transmitConfig: any = {
  pingInterval: '30s',
  transport: {
    driver: { name: 'disabled' },
  },
}

if (!transmitDisabled) {
  const { defineConfig } = await import('@adonisjs/transmit')
  const { redis } = await import('@adonisjs/transmit/transports')

  Object.assign(
    transmitConfig,
    defineConfig({
      pingInterval: '30s',
      transport: {
        driver: redis({
          host: env.get('REDIS_HOST'),
          port: env.get('REDIS_PORT'),
          keyPrefix: 'transmit:',
        }),
      },
    })
  )
}

export default transmitConfig
