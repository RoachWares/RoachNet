import env from '#start/env'
import { defineConfig } from '@adonisjs/transmit'
import { redis } from '@adonisjs/transmit/transports'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] transmit')
}

export default defineConfig({
  pingInterval: '30s',
  transport: {
    driver: redis({
      host: env.get('REDIS_HOST'),
      port: env.get('REDIS_PORT'),
      keyPrefix: 'transmit:',
    })
  }
})
