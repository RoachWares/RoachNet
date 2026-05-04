import Service from '#models/service'
import { BaseSeeder } from '@adonisjs/lucid/seeders'
import { ModelAttributes } from '@adonisjs/lucid/types/model'
import env from '#start/env'
import { SERVICE_NAMES } from '../../constants/service_names.js'

export default class ServiceSeeder extends BaseSeeder {
  // Use environment variable with fallback to production default
  private static ROACHNET_STORAGE_ABS_PATH = env.get(
    'ROACHNET_STORAGE_PATH',
    '/opt/roachnet/storage'
  )
  private static DEFAULT_SERVICES: Omit<
    ModelAttributes<Service>,
    'created_at' | 'updated_at' | 'metadata' | 'id' | 'available_update_version' | 'update_checked_at'
  >[] = [
    {
      service_name: SERVICE_NAMES.KIWIX,
      friendly_name: 'RoachNet Library',
      powered_by: 'Kiwix',
      display_order: 1,
      description:
        'Offline encyclopedias, field manuals, and reference archives staged inside RoachNet',
      icon: 'IconBooks',
      container_image: 'ghcr.io/kiwix/kiwix-serve:3.8.1',
      source_repo: 'https://github.com/kiwix/kiwix-tools',
      container_command: '*.zim --address=all',
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          Binds: [`${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/zim:/data`],
          PortBindings: { '8080/tcp': [{ HostPort: '8090' }] },
        },
        ExposedPorts: { '8080/tcp': {} },
      }),
      ui_location: '8090',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: false,
      depends_on: null,
    },
    {
      service_name: SERVICE_NAMES.QDRANT,
      friendly_name: 'Qdrant Vector Database',
      powered_by: null,
      display_order: 100, // Dependency service, not shown directly
      description: 'Vector database for storing and searching embeddings',
      icon: 'IconRobot',
      container_image: 'qdrant/qdrant:v1.16',
      source_repo: 'https://github.com/qdrant/qdrant',
      container_command: null,
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          Binds: [`${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/qdrant:/qdrant/storage`],
          PortBindings: { '6333/tcp': [{ HostPort: '6333' }], '6334/tcp': [{ HostPort: '6334' }] },
        },
        ExposedPorts: { '6333/tcp': {}, '6334/tcp': {} },
      }),
      ui_location: '6333',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: true,
      depends_on: null,
    },
    {
      service_name: SERVICE_NAMES.OLLAMA,
      friendly_name: 'RoachNet Chat',
      powered_by: 'Ollama',
      display_order: 3,
      description: 'Local AI chat and model tooling managed from the RoachNet command grid',
      icon: 'IconWand',
      container_image: 'ollama/ollama:0.18.1',
      source_repo: 'https://github.com/ollama/ollama',
      container_command: 'serve',
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          Binds: [`${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/ollama:/root/.ollama`],
          PortBindings: { '11434/tcp': [{ HostPort: '11434' }] },
        },
        ExposedPorts: { '11434/tcp': {} },
      }),
      ui_location: '/chat',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: false,
      depends_on: SERVICE_NAMES.QDRANT,
    },
    {
      service_name: SERVICE_NAMES.CYBERCHEF,
      friendly_name: 'RoachNet Data Lab',
      powered_by: 'CyberChef + Jam',
      display_order: 11,
      description: 'Encoding, decoding, and analysis tools adapted for RoachNet field workflows',
      icon: 'IconChefHat',
      container_image: 'ghcr.io/gchq/cyberchef:10.22.1',
      source_repo: 'https://github.com/gchq/CyberChef',
      container_command: null,
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          PortBindings: { '80/tcp': [{ HostPort: '8100' }] },
        },
        ExposedPorts: { '80/tcp': {} },
      }),
      ui_location: '8100',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: false,
      depends_on: null,
    },
    {
      service_name: SERVICE_NAMES.FLATNOTES,
      friendly_name: 'RoachNet Notes',
      powered_by: 'FlatNotes',
      display_order: 10,
      description: 'Fast local notes for fragments, checklists, and working references on the same machine',
      icon: 'IconNotes',
      container_image: 'dullage/flatnotes:v5.5.4',
      source_repo: 'https://github.com/dullage/flatnotes',
      container_command: null,
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          PortBindings: { '8080/tcp': [{ HostPort: '8200' }] },
          Binds: [`${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/flatnotes:/data`],
        },
        ExposedPorts: { '8080/tcp': {} },
        Env: ['FLATNOTES_AUTH_TYPE=none'],
      }),
      ui_location: '8200',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: false,
      depends_on: null,
    },
    {
      service_name: SERVICE_NAMES.KOLIBRI,
      friendly_name: 'RoachNet Academy',
      powered_by: 'Kolibri',
      display_order: 2,
      description: 'Structured offline education content and coursework surfaced through RoachNet',
      icon: 'IconSchool',
      container_image: 'treehouses/kolibri:0.12.8',
      source_repo: 'https://github.com/learningequality/kolibri',
      container_command: null,
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          PortBindings: { '8080/tcp': [{ HostPort: '8300' }] },
          Binds: [`${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/kolibri:/root/.kolibri`],
        },
        ExposedPorts: { '8080/tcp': {} },
      }),
      ui_location: '8300',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: false,
      depends_on: null,
    },
    {
      service_name: SERVICE_NAMES.ROACHSYNC,
      friendly_name: 'RoachSync',
      powered_by: 'Syncthing',
      display_order: 4,
      description: 'Private device sync for the RoachNet vault, app settings, and future multi-device state.',
      icon: 'IconArrowsExchange',
      container_image: 'syncthing/syncthing:latest',
      source_repo: 'https://github.com/syncthing/syncthing',
      container_command: null,
      container_config: JSON.stringify({
        HostConfig: {
          RestartPolicy: { Name: 'unless-stopped' },
          PortBindings: {
            '8384/tcp': [{ HostPort: '8384' }],
            '22000/tcp': [{ HostPort: '22000' }],
            '22000/udp': [{ HostPort: '22000' }],
            '21027/udp': [{ HostPort: '21027' }],
          },
          Binds: [
            `${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/roachsync/config:/var/syncthing/config`,
            `${ServiceSeeder.ROACHNET_STORAGE_ABS_PATH}/vault:/var/syncthing/vault`,
          ],
        },
        ExposedPorts: {
          '8384/tcp': {},
          '22000/tcp': {},
          '22000/udp': {},
          '21027/udp': {},
        },
      }),
      ui_location: '8384',
      installed: false,
      installation_status: 'idle',
      is_dependency_service: false,
      depends_on: null,
    },
  ]

  async run() {
    const existingServices = await Service.all()
    const existingServiceNames = new Set(existingServices.map((service) => service.service_name))
    const defaultsByName = new Map(
      ServiceSeeder.DEFAULT_SERVICES.map((service) => [service.service_name, service])
    )

    for (const service of existingServices) {
      const defaults = defaultsByName.get(service.service_name)
      if (!defaults) {
        continue
      }

      service.merge({
        ...defaults,
        installed: service.installed,
        installation_status: service.installation_status,
      })
      await service.save()
    }

    const newServices = ServiceSeeder.DEFAULT_SERVICES.filter(
      (service) => !existingServiceNames.has(service.service_name)
    )

    await Service.createMany([...newServices])
  }
}
