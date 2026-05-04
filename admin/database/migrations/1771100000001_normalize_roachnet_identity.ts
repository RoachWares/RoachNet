import { BaseSchema } from '@adonisjs/lucid/schema'

export default class extends BaseSchema {
  async up() {
    const legacyPrefix = ['no', 'mad_'].join('')
    const servicePairs = [
      ['kiwix_server', 'kiwix_server'],
      ['kiwix_serve', 'kiwix_serve'],
      ['ollama', 'ollama'],
      ['qdrant', 'qdrant'],
      ['cyberchef', 'cyberchef'],
      ['flatnotes', 'flatnotes'],
      ['kolibri', 'kolibri'],
      ['syncthing', 'syncthing'],
    ]

    for (const [legacyName, roachNetName] of servicePairs) {
      await this.db
        .from('services')
        .where('service_name', `${legacyPrefix}${legacyName}`)
        .update({ service_name: `roachnet_${roachNetName}` })

      await this.db
        .from('services')
        .where('depends_on', `${legacyPrefix}${legacyName}`)
        .update({ depends_on: `roachnet_${roachNetName}` })
    }

    const legacyScoreColumn = `${legacyPrefix}score`
    const hasLegacyScore = await this.schema.hasColumn('benchmark_results', legacyScoreColumn)
    const hasRoachNetScore = await this.schema.hasColumn('benchmark_results', 'roachnet_score')

    if (hasLegacyScore && !hasRoachNetScore) {
      await this.schema.alterTable('benchmark_results', (table) => {
        table.renameColumn(legacyScoreColumn, 'roachnet_score')
      })
    }
  }

  async down() {
    const legacyPrefix = ['no', 'mad_'].join('')
    const servicePairs = [
      ['kiwix_server', 'kiwix_server'],
      ['kiwix_serve', 'kiwix_serve'],
      ['ollama', 'ollama'],
      ['qdrant', 'qdrant'],
      ['cyberchef', 'cyberchef'],
      ['flatnotes', 'flatnotes'],
      ['kolibri', 'kolibri'],
      ['syncthing', 'syncthing'],
    ]

    for (const [legacyName, roachNetName] of servicePairs) {
      await this.db
        .from('services')
        .where('service_name', `roachnet_${roachNetName}`)
        .update({ service_name: `${legacyPrefix}${legacyName}` })

      await this.db
        .from('services')
        .where('depends_on', `roachnet_${roachNetName}`)
        .update({ depends_on: `${legacyPrefix}${legacyName}` })
    }

    const legacyScoreColumn = `${legacyPrefix}score`
    const hasLegacyScore = await this.schema.hasColumn('benchmark_results', legacyScoreColumn)
    const hasRoachNetScore = await this.schema.hasColumn('benchmark_results', 'roachnet_score')

    if (hasRoachNetScore && !hasLegacyScore) {
      await this.schema.alterTable('benchmark_results', (table) => {
        table.renameColumn('roachnet_score', legacyScoreColumn)
      })
    }
  }
}
