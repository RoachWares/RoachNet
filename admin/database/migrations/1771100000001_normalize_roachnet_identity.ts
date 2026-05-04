import { BaseSchema } from '@adonisjs/lucid/schema'

export default class extends BaseSchema {
  private isDuplicateColumnError(error: unknown) {
    return error instanceof Error && error.message.toLowerCase().includes('duplicate column')
  }

  private async renameServicePreservingDependencies(fromName: string, toName: string) {
    const existingSource = await this.db.from('services').where('service_name', fromName).first()
    if (!existingSource) {
      return
    }

    const existingTarget = await this.db.from('services').where('service_name', toName).first()
    if (!existingTarget) {
      const serviceValues = { ...existingSource }
      delete serviceValues.id
      delete serviceValues.service_name
      await this.db.table('services').insert({
        ...serviceValues,
        service_name: toName,
      })
    }

    await this.db.from('services').where('depends_on', fromName).update({ depends_on: toName })
    await this.db.from('services').where('service_name', fromName).delete()
  }

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
      await this.renameServicePreservingDependencies(
        `${legacyPrefix}${legacyName}`,
        `roachnet_${roachNetName}`
      )
    }

    const legacyScoreColumn = `${legacyPrefix}score`
    const hasLegacyScore = await this.schema.hasColumn('benchmark_results', legacyScoreColumn)
    const hasRoachNetScore = await this.schema.hasColumn('benchmark_results', 'roachnet_score')

    if (hasLegacyScore && !hasRoachNetScore) {
      try {
        await this.db.rawQuery('ALTER TABLE benchmark_results ADD COLUMN roachnet_score FLOAT')
      } catch (error) {
        if (!this.isDuplicateColumnError(error)) {
          throw error
        }
      }
      await this.db.rawQuery(
        `UPDATE benchmark_results SET roachnet_score = ${legacyScoreColumn} WHERE roachnet_score IS NULL`
      )
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
      await this.renameServicePreservingDependencies(
        `roachnet_${roachNetName}`,
        `${legacyPrefix}${legacyName}`
      )
    }

    const legacyScoreColumn = `${legacyPrefix}score`
    const hasLegacyScore = await this.schema.hasColumn('benchmark_results', legacyScoreColumn)
    const hasRoachNetScore = await this.schema.hasColumn('benchmark_results', 'roachnet_score')

    if (hasRoachNetScore && !hasLegacyScore) {
      try {
        await this.db.rawQuery(`ALTER TABLE benchmark_results ADD COLUMN ${legacyScoreColumn} FLOAT`)
      } catch (error) {
        if (!this.isDuplicateColumnError(error)) {
          throw error
        }
      }
      await this.db.rawQuery(
        `UPDATE benchmark_results SET ${legacyScoreColumn} = roachnet_score WHERE ${legacyScoreColumn} IS NULL`
      )
    }
  }
}
