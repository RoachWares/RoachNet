import app from '@adonisjs/core/services/app'
import { HttpContext, ExceptionHandler } from '@adonisjs/core/http'
import type { StatusPageRange, StatusPageRenderer } from '@adonisjs/core/types/http'

export default class HttpExceptionHandler extends ExceptionHandler {
  /**
   * In debug mode, the exception handler will display verbose errors
   * with pretty printed stack traces.
   */
  protected debug = !app.inProduction

  /**
   * RoachNet is now primarily a native app, so production API errors should not
   * attempt to render Inertia status pages.
   */
  protected renderStatusPages = false

  /**
   * Status pages are retained for any future HTML flows, but are disabled above.
   */
  protected statusPages: Record<StatusPageRange, StatusPageRenderer> = {
    '404': (error, { inertia }) => inertia.render('errors/not_found', { error }),
    '500..599': (error, { inertia }) => inertia.render('errors/server_error', { error }),
  }

  /**
   * The method is used for handling errors and returning
   * response to the client
   */
  async handle(error: unknown, ctx: HttpContext) {
    const status =
      error && typeof error === 'object' && 'status' in error && typeof error.status === 'number'
        ? error.status
        : 500
    const message =
      error && typeof error === 'object' && 'message' in error
        ? String(error.message)
        : 'Unexpected server error'
    const expectsJson =
      ctx.request.url().startsWith('/api') || ctx.request.accepts(['html', 'json']) === 'json'

    if (expectsJson) {
      ctx.response.status(status).send({ error: message })
      return
    }

    if (!app.inProduction) {
      const details =
        error && typeof error === 'object'
          ? {
              name: 'name' in error ? String(error.name) : error.constructor?.name,
              message: 'message' in error ? String(error.message) : String(error),
              code: 'code' in error ? String(error.code) : undefined,
              status: 'status' in error ? Number(error.status) : undefined,
            }
          : {
              name: typeof error,
              message: String(error),
              code: undefined,
              status: undefined,
            }

      console.error('[HttpExceptionHandler.handle]', {
        ...details,
        method: ctx.request.method(),
        path: ctx.request.url(true),
      })
    }

    ctx.response.status(status).send(message)
    return
  }

  /**
   * The method is used to report error to the logging service or
   * the a third party error monitoring service.
   *
   * @note You should not attempt to send a response from this method.
   */
  async report(error: unknown, ctx: HttpContext) {
    if (!app.inProduction) {
      const details =
        error && typeof error === 'object'
          ? {
              name: 'name' in error ? String(error.name) : error.constructor?.name,
              message: 'message' in error ? String(error.message) : String(error),
              code: 'code' in error ? String(error.code) : undefined,
              status: 'status' in error ? Number(error.status) : undefined,
            }
          : {
              name: typeof error,
              message: String(error),
              code: undefined,
              status: undefined,
            }

      console.error('[HttpExceptionHandler.report]', {
        ...details,
        method: ctx.request.method(),
        path: ctx.request.url(true),
      })
    }

    return super.report(error, ctx)
  }
}
