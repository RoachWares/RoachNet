import env from '#start/env'
import { defineConfig, drivers } from '@adonisjs/core/encryption'
import type { InferEncryptors } from '@adonisjs/core/types'

const encryptionConfig = defineConfig({
  default: 'app',

  list: {
    app: drivers.aes256gcm({
      id: 'app',
      keys: [env.get('APP_KEY')],
    }),
  },
})

export default encryptionConfig

declare module '@adonisjs/core/types' {
  export interface EncryptorsList extends InferEncryptors<typeof encryptionConfig> {}
}
