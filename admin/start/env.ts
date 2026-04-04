/*
|--------------------------------------------------------------------------
| Environment variables service
|--------------------------------------------------------------------------
|
| The `Env.create` method creates an instance of the Env service. The
| service validates the environment variables and also cast values
| to JavaScript data types.
|
*/

import { Env } from '@adonisjs/core/env'

export default await Env.create(new URL('../', import.meta.url), {
  NODE_ENV: Env.schema.enum(['development', 'production', 'test'] as const),
  PORT: Env.schema.number(),
  APP_KEY: Env.schema.string(),
  HOST: Env.schema.string({ format: 'host' }),
  URL: Env.schema.string(),
  LOG_LEVEL: Env.schema.string(),
  INTERNET_STATUS_TEST_URL: Env.schema.string.optional(),

  /*
  |----------------------------------------------------------
  | Variables for configuring storage paths
  |----------------------------------------------------------
  */
  NOMAD_STORAGE_PATH: Env.schema.string.optional(),

  /*
  |----------------------------------------------------------
  | Variables for configuring session package
  |----------------------------------------------------------
  */
  //SESSION_DRIVER: Env.schema.enum(['cookie', 'memory'] as const),

  /*
  |----------------------------------------------------------
  | Variables for configuring the database package
  |----------------------------------------------------------
  */
  DB_CONNECTION: Env.schema.enum.optional(['mysql', 'sqlite'] as const),
  DB_HOST: Env.schema.string.optional({ format: 'host' }),
  DB_PORT: Env.schema.number.optional(),
  DB_USER: Env.schema.string.optional(),
  DB_PASSWORD: Env.schema.string.optional(),
  DB_DATABASE: Env.schema.string.optional(),
  DB_SSL: Env.schema.boolean.optional(),
  SQLITE_DB_PATH: Env.schema.string.optional(),

  /*
  |----------------------------------------------------------
  | Variables for configuring the Redis connection
  |----------------------------------------------------------
  */
  REDIS_HOST: Env.schema.string.optional({ format: 'host' }),
  REDIS_PORT: Env.schema.number.optional(),

  /*
  |----------------------------------------------------------
  | Variables for configuring external AI runtime URLs
  |----------------------------------------------------------
  */
  NOMAD_API_URL: Env.schema.string.optional(),
  OLLAMA_BASE_URL: Env.schema.string.optional(),
  OPENCLAW_BASE_URL: Env.schema.string.optional(),
  OPENCLAW_WORKSPACE_PATH: Env.schema.string.optional(),
})
