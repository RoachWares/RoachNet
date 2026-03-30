import env from '#start/env'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] queue')
}

const queueConfig = {
  connection: {
    host: env.get('REDIS_HOST'),
    port: env.get('REDIS_PORT') ?? 6379,
  },
}

export default queueConfig
