import { Head } from '@inertiajs/react'
import { IconExternalLink } from '@tabler/icons-react'
import SettingsLayout from '~/layouts/SettingsLayout'

export default function SupportPage() {
  return (
    <SettingsLayout>
      <Head title="Support RoachNet | RoachNet" />
      <div className="xl:pl-72 w-full">
        <main className="px-12 py-6 max-w-4xl">
          <h1 className="text-4xl font-semibold mb-4">Support RoachNet</h1>
          <p className="text-text-muted mb-10 text-lg">
            RoachNet is being built as an offline-first command grid for local AI, maps,
            documents, and day-to-day disconnected workflows. The highest-value support right now
            is practical feedback, bug reports, and real-world testing.
          </p>

          <section className="mb-12">
            <h2 className="text-2xl font-semibold mb-3">Follow the Build</h2>
            <p className="text-text-muted mb-4">
              Track changes, review the source, and star the repo if you want to help more people
              find the project.
            </p>
            <a
              href="https://github.com/RoachWares/RoachNet"
              target="_blank"
              rel="noopener noreferrer"
              className="roachnet-button roachnet-button--primary inline-flex items-center gap-2 rounded-lg bg-desert-green px-5 py-2.5 font-semibold text-desert-green-darker transition-colors hover:bg-btn-green-hover"
            >
              <span className="relative z-10 inline-flex items-center gap-2">
                Open the GitHub Repo
                <IconExternalLink size={18} />
              </span>
            </a>
          </section>

          <section className="mb-12">
            <h2 className="text-2xl font-semibold mb-3">Report Issues and Request Features</h2>
            <p className="text-text-muted mb-4">
              If something breaks, if onboarding is unclear, or if there is an offline workflow
              RoachNet should support, open an issue with reproduction steps and environment
              details.
            </p>
            <a
              href="https://github.com/RoachWares/RoachNet/issues"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 text-desert-green hover:underline font-medium"
            >
              Open Issues
              <IconExternalLink size={16} />
            </a>
          </section>

          <section className="mb-10">
            <h2 className="text-2xl font-semibold mb-3">Best Ways to Help</h2>
            <ul className="space-y-2 text-text-muted">
              <li>
                <a
                  href="https://github.com/RoachWares/RoachNet"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-desert-green hover:underline"
                >
                  Star the project on GitHub
                </a>
                {' '}— it helps more people discover RoachNet
              </li>
              <li>
                <a
                  href="https://github.com/RoachWares/RoachNet/issues"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-desert-green hover:underline"
                >
                  Report bugs and suggest features
                </a>
                {' '}— every report makes RoachNet better
              </li>
              <li>Share field notes, screenshots, and workflow gaps so the product can be shaped around real offline use cases.</li>
              <li>Test setup, model downloads, and content installs on actual hardware and report where the UX still gets in the way.</li>
            </ul>
          </section>

        </main>
      </div>
    </SettingsLayout>
  )
}
