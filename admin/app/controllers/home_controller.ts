import { SystemService } from '#services/system_service'
import { inject } from '@adonisjs/core'
import type { HttpContext } from '@adonisjs/core/http'

@inject()
export default class HomeController {
    constructor(
        private systemService: SystemService,
    ) { }

    async index({ response }: HttpContext) {
        // Redirect / to /home
        return response.redirect().toPath('/home');
    }

    async home({ inertia, response }: HttpContext) {
        const services = await this.systemService.getServices({ installedOnly: true });

        if (inertia && typeof inertia.render === 'function') {
            return inertia.render('home', {
                system: {
                    services
                }
            })
        }

        const serviceMarkup = services.length > 0
            ? services
                .map((service) => `<li><strong>${service.friendly_name}</strong> · ${service.status}</li>`)
                .join('')
            : '<li>No managed services are installed yet.</li>'

        return response
            .status(200)
            .header('content-type', 'text/html; charset=utf-8')
            .send(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>RoachNet</title>
    <style>
      :root { color-scheme: dark; }
      body {
        margin: 0;
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
        background: radial-gradient(circle at top, #142235 0%, #091018 55%, #05070b 100%);
        color: #eef3f8;
      }
      main {
        max-width: 720px;
        margin: 0 auto;
        padding: 64px 24px;
      }
      h1 { font-size: 40px; line-height: 1; margin: 0 0 16px; }
      p { color: rgba(238,243,248,0.78); font-size: 16px; line-height: 1.6; }
      ul { margin: 28px 0 0; padding-left: 20px; color: rgba(238,243,248,0.88); }
      li { margin: 10px 0; }
      .chip {
        display: inline-block;
        margin-top: 20px;
        padding: 10px 14px;
        border-radius: 999px;
        background: rgba(102, 224, 191, 0.14);
        color: #7af0c7;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 13px;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>RoachNet runtime is online.</h1>
      <p>The native app now owns the main experience. This fallback page is only here so direct browser hits to <code>/home</code> do not crash when the Inertia web shell is unavailable.</p>
      <div class="chip">127.0.0.1:8080 · native lane</div>
      <ul>${serviceMarkup}</ul>
    </main>
  </body>
</html>`)
    }
}
