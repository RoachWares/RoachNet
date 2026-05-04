/*
|--------------------------------------------------------------------------
| HTTP kernel file
|--------------------------------------------------------------------------
|
| The HTTP kernel file is used to register the middleware with the server
| or the router.
|
*/

import router from '@adonisjs/core/services/router'
import server from '@adonisjs/core/services/server'

const nativeOnly = process.env.ROACHNET_NATIVE_ONLY === '1'

/**
 * The error handler is used to convert an exception
 * to an HTTP response.
 */
server.errorHandler(() => import('#exceptions/handler'))

/**
 * The server middleware stack runs middleware on all the HTTP
 * requests, even if there is no route registered for
 * the request URL.
 */
server.use([
  () => import('#middleware/container_bindings_middleware'),
  () => import('@adonisjs/cors/cors_middleware'),
  ...(nativeOnly ? [] : [() => import('@adonisjs/vite/vite_middleware')]),
  ...(nativeOnly ? [] : [() => import('#middleware/inertia_middleware')]),
  ...(nativeOnly ? [] : [() => import('@adonisjs/static/static_middleware')]),
  ...(nativeOnly ? [] : [() => import('#middleware/maps_static_middleware')]),
])

/**
 * The router middleware stack runs middleware on all the HTTP
 * requests with a registered route.
 */
router.use([
  ...(nativeOnly ? [() => import('#middleware/native_request_probe_middleware')] : []),
  () => import('@adonisjs/core/bodyparser_middleware'),
  // () => import('@adonisjs/session/session_middleware'),
  ...(nativeOnly ? [] : [() => import('@adonisjs/shield/shield_middleware')]),
])

/**
 * Named middleware collection must be explicitly assigned to
 * the routes or the routes group.
 */
export const middleware = router.named({})
