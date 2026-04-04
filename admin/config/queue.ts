import env from '#start/env'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] queue')
}

const queueDisabled =
  process.env.ROACHNET_DISABLE_QUEUE === '1' ||
  !env.get('REDIS_HOST') ||
  !env.get('REDIS_PORT')

const queueConfig = {
  disabled: queueDisabled,
  connection: queueDisabled
    ? null
    : {
        host: env.get('REDIS_HOST'),
        port: env.get('REDIS_PORT') ?? 6379,
      },
}

export default queueConfig
