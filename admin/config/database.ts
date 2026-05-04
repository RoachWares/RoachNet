import env from '#start/env'
import { defineConfig } from '@adonisjs/lucid'
import path from 'node:path'

if (process.env.ROACHNET_DEBUG_BOOT === '1') {
  console.log('[roachnet:config] database')
}

const connection = env.get('DB_CONNECTION') ?? 'mysql'
const sqliteFilename =
  env.get('SQLITE_DB_PATH') ??
  path.join(env.get('ROACHNET_STORAGE_PATH') || process.cwd(), 'state', 'roachnet.sqlite')

const dbConfig = defineConfig({
  connection,
  connections: {
    mysql: {
      client: 'mysql2',
      debug: env.get('NODE_ENV') === 'development',
      connection: {
        host: env.get('DB_HOST'),
        port: env.get('DB_PORT') ?? 3306, // Default MySQL port
        user: env.get('DB_USER'),
        password: env.get('DB_PASSWORD'),
        database: env.get('DB_DATABASE'),
        ssl: env.get('DB_SSL') ?? true, // Default to true
      },
      migrations: {
        naturalSort: true,
        paths: ['database/migrations'],
      },
    },
    sqlite: {
      client: 'better-sqlite3',
      connection: {
        filename: sqliteFilename,
      },
      useNullAsDefault: true,
      migrations: {
        naturalSort: true,
        paths: ['database/migrations'],
      },
    },
  },
})

export default dbConfig
