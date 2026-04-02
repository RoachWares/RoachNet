import Service from '#models/service'
import KVStore from '#models/kv_store'
import { inject } from '@adonisjs/core'
import logger from '@adonisjs/core/services/logger'
import { DockerService } from '#services/docker_service'
import { SERVICE_NAMES } from '../../constants/service_names.js'
import { ServiceSlim } from '../../types/services.js'
import {
  GpuHealthStatus,
  HardwareMemoryTier,
  HardwareProfile,
  NomadDiskInfo,
  NomadDiskInfoRaw,
  SystemInformationResponse,
} from '../../types/system.js'
import { KV_STORE_SCHEMA, KVStoreKey } from '../../types/kv_store.js'
import { getAllFilesystems, getFile } from '../utils/fs.js'
import { isNewerVersion } from '../utils/version.js'
import axios from 'axios'
import env from '#start/env'
import { readFileSync } from 'fs'
import path, { join } from 'path'
import si from 'systeminformation'

@inject()
export class SystemService {
  private static appVersion: string | null = null
  private static readonly diskInfoFile = '/storage/nomad-disk-info.json'
  private static internetStatusCache:
    | { value: boolean; expiresAt: number }
    | null = null
  private static systemInfoCache:
    | { value: SystemInformationResponse; expiresAt: number }
    | null = null
  private static servicesCache:
    | { value: ServiceSlim[]; expiresAt: number }
    | null = null
  private static servicesInflight: Promise<ServiceSlim[]> | null = null
  private static repairSweepPromise: Promise<void> | null = null
  private static readonly INTERNET_STATUS_CACHE_TTL_MS = 15_000
  private static readonly SYSTEM_INFO_CACHE_TTL_MS = 10_000
  private static readonly SERVICES_CACHE_TTL_MS = 5_000

  constructor(private dockerService: DockerService) {}

  async checkServiceInstalled(serviceName: string): Promise<boolean> {
    const services = await this.getServices({ installedOnly: true })
    return services.some((service) => service.service_name === serviceName)
  }

  async getInternetStatus(): Promise<boolean> {
    const now = Date.now()
    if (SystemService.internetStatusCache && SystemService.internetStatusCache.expiresAt > now) {
      return SystemService.internetStatusCache.value
    }

    const testUrl = this.getInternetTestUrl()
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const response = await axios.get(testUrl, { timeout: 5000 })
        const connected = response.status === 200
        SystemService.internetStatusCache = {
          value: connected,
          expiresAt: now + SystemService.INTERNET_STATUS_CACHE_TTL_MS,
        }
        return connected
      } catch (error) {
        logger.warn(
          `Internet status check attempt ${attempt}/3 failed: ${error instanceof Error ? error.message : error}`
        )
        if (attempt < 3) {
          await new Promise((resolve) => setTimeout(resolve, 1000))
        }
      }
    }

    SystemService.internetStatusCache = {
      value: false,
      expiresAt: now + SystemService.INTERNET_STATUS_CACHE_TTL_MS,
    }
    return false
  }

  async getNvidiaSmiInfo(): Promise<
    Array<{ vendor: string; model: string; vram: number }> |
    { error: string } |
    'OLLAMA_NOT_FOUND' |
    'BAD_RESPONSE' |
    'UNKNOWN_ERROR'
  > {
    try {
      const containers = await this.dockerService.docker.listContainers({ all: false })
      const ollamaContainer = containers.find((container) =>
        container.Names.includes(`/${SERVICE_NAMES.OLLAMA}`)
      )
      if (!ollamaContainer) {
        return 'OLLAMA_NOT_FOUND'
      }

      const exec = await this.dockerService.docker.getContainer(ollamaContainer.Id).exec({
        Cmd: ['nvidia-smi', '--query-gpu=name,memory.total', '--format=csv,noheader,nounits'],
        AttachStdout: true,
        AttachStderr: true,
        Tty: true,
      })
      const stream = await exec.start({ Tty: true })
      const output = await new Promise<string>((resolve) => {
        let data = ''
        const timeout = setTimeout(() => resolve(data), 5000)
        stream.on('data', (chunk: Buffer) => {
          data += chunk.toString()
        })
        stream.on('end', () => {
          clearTimeout(timeout)
          resolve(data)
        })
      })

      const cleaned = output.replace(/[\x00-\x08]/g, '').trim()
      if (!cleaned || cleaned.toLowerCase().includes('error') || cleaned.toLowerCase().includes('not found')) {
        return 'BAD_RESPONSE'
      }

      return cleaned
        .split('\n')
        .filter(Boolean)
        .map((line) => {
          const [model, rawVram] = line.split(',').map((entry) => entry.trim())
          return {
            vendor: 'NVIDIA',
            model: model || 'NVIDIA GPU',
            vram: rawVram ? parseInt(rawVram, 10) : 0,
          }
        })
    } catch (error) {
      logger.error('Error getting nvidia-smi info:', error)
      if (error instanceof Error) {
        return { error: error.message }
      }
      return 'UNKNOWN_ERROR'
    }
  }

  async getServices({ installedOnly = true }: { installedOnly?: boolean }): Promise<ServiceSlim[]> {
    const now = Date.now()
    if (SystemService.servicesCache && SystemService.servicesCache.expiresAt > now) {
      return this.filterServices(SystemService.servicesCache.value, installedOnly)
    }

    if (!SystemService.servicesInflight) {
      SystemService.servicesInflight = this.buildServicesSnapshot()
        .then((services) => {
          SystemService.servicesCache = {
            value: services,
            expiresAt: Date.now() + SystemService.SERVICES_CACHE_TTL_MS,
          }
          return services
        })
        .finally(() => {
          SystemService.servicesInflight = null
        })
    }

    return this.filterServices(await SystemService.servicesInflight, installedOnly)
  }

  static getAppVersion(): string {
    try {
      if (this.appVersion) {
        return this.appVersion
      }

      if (process.env.NODE_ENV === 'development') {
        this.appVersion = 'dev'
        return 'dev'
      }

      const versionData = JSON.parse(readFileSync(join(process.cwd(), 'version.json'), 'utf-8'))
      this.appVersion = versionData.version || '0.0.0'
      return this.appVersion
    } catch (error) {
      logger.error('Error getting app version:', error)
      return '0.0.0'
    }
  }

  async getSystemInfo(): Promise<SystemInformationResponse | undefined> {
    try {
      const now = Date.now()
      if (SystemService.systemInfoCache && SystemService.systemInfoCache.expiresAt > now) {
        return SystemService.systemInfoCache.value
      }

      const fallbackCpu = {
        manufacturer: 'Unknown',
        brand: 'Unavailable',
        physicalCores: 0,
        cores: 0,
      } as SystemInformationResponse['cpu']
      const fallbackMem = {
        total: 0,
        available: 0,
        swapused: 0,
      } as SystemInformationResponse['mem']
      const fallbackOs = {
        hostname: 'roachnet',
        arch: process.arch,
        distro: 'Unavailable',
      } as SystemInformationResponse['os']
      const fallbackCurrentLoad = {
        currentLoad: 0,
      } as SystemInformationResponse['currentLoad']
      const fallbackUptime = {
        uptime: 0,
      } as SystemInformationResponse['uptime']
      const fallbackGraphics = {
        controllers: [],
        displays: [],
      } as SystemInformationResponse['graphics']

      const [cpu, mem, os, currentLoad, fsSize, uptime, graphics] = await Promise.all([
        this.withTimeout('systeminformation.cpu', () => si.cpu(), fallbackCpu, 2000),
        this.withTimeout('systeminformation.mem', () => si.mem(), fallbackMem, 2000),
        this.withTimeout('systeminformation.osInfo', () => si.osInfo(), fallbackOs, 2000),
        this.withTimeout(
          'systeminformation.currentLoad',
          () => si.currentLoad(),
          fallbackCurrentLoad,
          2000
        ),
        this.withTimeout('systeminformation.fsSize', () => si.fsSize(), [], 2000),
        this.withTimeout('systeminformation.time', () => si.time(), fallbackUptime, 2000),
        this.withTimeout('systeminformation.graphics', () => si.graphics(), fallbackGraphics, 2500),
      ])

      let disk: NomadDiskInfo[] = []
      try {
        const diskInfoRawString = await getFile(
          path.join(process.cwd(), SystemService.diskInfoFile),
          'string'
        )
        const diskInfo = (
          diskInfoRawString
            ? JSON.parse(diskInfoRawString.toString())
            : { diskLayout: { blockdevices: [] }, fsSize: [] }
        ) as NomadDiskInfoRaw
        disk = this.calculateDiskUsage(diskInfo)
      } catch (error) {
        logger.error('Error reading disk info file:', error)
      }

      const gpuHealth: GpuHealthStatus = {
        status: 'no_gpu',
        hasNvidiaRuntime: false,
        ollamaGpuAccessible: false,
      }

      try {
        const dockerInfo = await this.withTimeout<any>(
          'docker.info',
          () => this.dockerService.docker.info(),
          null,
          1500
        )

        if (dockerInfo) {
          if (dockerInfo.Name) os.hostname = dockerInfo.Name
          if (dockerInfo.OperatingSystem) os.distro = dockerInfo.OperatingSystem
          if (dockerInfo.KernelVersion) os.kernel = dockerInfo.KernelVersion

          if ((!graphics.controllers || graphics.controllers.length === 0) && dockerInfo.Runtimes?.nvidia) {
            gpuHealth.hasNvidiaRuntime = true
            const nvidiaInfo = await this.withTimeout(
              'nvidia-smi probe',
              () => this.getNvidiaSmiInfo(),
              'BAD_RESPONSE' as Awaited<ReturnType<SystemService['getNvidiaSmiInfo']>>,
              2500
            )

            if (Array.isArray(nvidiaInfo)) {
              graphics.controllers = nvidiaInfo.map((gpu) => ({
                model: gpu.model,
                vendor: gpu.vendor,
                bus: '',
                vram: gpu.vram,
                vramDynamic: false,
              }))
              gpuHealth.status = 'ok'
              gpuHealth.ollamaGpuAccessible = true
            } else if (nvidiaInfo === 'OLLAMA_NOT_FOUND') {
              gpuHealth.status = 'ollama_not_installed'
            } else {
              gpuHealth.status = 'passthrough_failed'
            }
          } else if (graphics.controllers && graphics.controllers.length > 0) {
            gpuHealth.status = 'ok'
            gpuHealth.ollamaGpuAccessible = true
          }
        }
      } catch {
        // best-effort enrichment only
      }

      const systemInfo: SystemInformationResponse = {
        cpu,
        mem,
        os,
        disk,
        currentLoad,
        fsSize,
        uptime,
        graphics,
        gpuHealth,
        hardwareProfile: this.buildHardwareProfile({ cpu, mem, os, currentLoad }),
      }

      SystemService.systemInfoCache = {
        value: systemInfo,
        expiresAt: now + SystemService.SYSTEM_INFO_CACHE_TTL_MS,
      }

      return systemInfo
    } catch (error) {
      logger.error('Error getting system info:', error)
      return undefined
    }
  }

  private buildHardwareProfile({
    cpu,
    mem,
    os,
    currentLoad,
  }: {
    cpu: SystemInformationResponse['cpu']
    mem: SystemInformationResponse['mem']
    os: SystemInformationResponse['os']
    currentLoad: SystemInformationResponse['currentLoad']
  }): HardwareProfile {
    const cpuSignature = `${cpu.manufacturer || ''} ${cpu.brand || ''}`.toLowerCase()
    const isAppleSilicon =
      os.arch === 'arm64' &&
      (cpuSignature.includes('apple') || /\bm[1-9]\b/.test(cpuSignature))
    const memoryTier = this.getMemoryTier(mem.total)
    const notes: string[] = []
    const warnings: string[] = []

    if (isAppleSilicon) {
      notes.push('Prefer host-native Ollama or OpenClaw endpoints over Docker-managed AI containers on Apple Silicon.')
      notes.push('Keep only the models you need loaded so unified memory stays available for maps, archives, and the UI.')
    } else if (os.arch === 'arm64') {
      notes.push('Prefer arm64-native builds and lighter quantized models to keep latency and thermals under control.')
    } else {
      notes.push('Local runtimes reduce orchestration overhead, but Docker-managed services remain acceptable on x86-64 hosts.')
    }

    if (memoryTier === 'compact') notes.push('Start with 4B to 8B quantized models.')
    if (memoryTier === 'balanced') notes.push('7B to 14B quantized models are the safest default.')
    if (memoryTier === 'creator') notes.push('14B to 32B class models are realistic if you avoid stacking too many other heavy services.')
    if (memoryTier === 'workstation') notes.push('This machine has enough headroom for larger local models and concurrent content services.')

    const memoryPressure = mem.total > 0 ? ((mem.total - mem.available) / mem.total) * 100 : 0
    if (memoryPressure >= 80) warnings.push('Memory pressure is already high.')
    if (mem.swapused > 0) warnings.push('Swap is active and model latency will rise.')
    if (currentLoad.currentLoad >= 85) warnings.push('CPU load is elevated.')
    if (isAppleSilicon && mem.total < 16 * 1024 * 1024 * 1024) {
      warnings.push('Unified memory is limited for Apple Silicon AI work.')
    }

    return {
      platformLabel: cpu.brand || cpu.manufacturer || os.arch,
      chipFamily: isAppleSilicon ? 'apple_silicon' : os.arch === 'arm64' ? 'arm64' : os.arch === 'x64' ? 'x86_64' : 'generic',
      isAppleSilicon,
      memoryTier,
      recommendedRuntime: isAppleSilicon || os.arch === 'arm64' ? 'native_local' : 'docker',
      recommendedModelClass: this.getRecommendedModelClass(memoryTier, isAppleSilicon),
      notes,
      warnings,
    }
  }

  private getMemoryTier(totalBytes: number): HardwareMemoryTier {
    const totalGb = totalBytes / (1024 * 1024 * 1024)
    if (totalGb < 16) return 'compact'
    if (totalGb < 32) return 'balanced'
    if (totalGb < 64) return 'creator'
    return 'workstation'
  }

  private getRecommendedModelClass(memoryTier: HardwareMemoryTier, isAppleSilicon: boolean): string {
    switch (memoryTier) {
      case 'compact':
        return isAppleSilicon ? '4B to 8B quantized models' : 'Small quantized models'
      case 'balanced':
        return '7B to 14B quantized models'
      case 'creator':
        return '14B to 32B quantized models'
      case 'workstation':
        return '32B+ local workflows'
    }
  }

  async checkLatestVersion(force?: boolean): Promise<{
    success: boolean
    updateAvailable: boolean
    currentVersion: string
    latestVersion: string
    message?: string
  }> {
    try {
      const currentVersion = SystemService.getAppVersion()
      const cachedUpdateAvailable = await KVStore.getValue('system.updateAvailable')
      const cachedLatestVersion = await KVStore.getValue('system.latestVersion')

      if (!force) {
        return {
          success: true,
          updateAvailable: cachedUpdateAvailable ?? false,
          currentVersion,
          latestVersion: cachedLatestVersion || '',
        }
      }

      const earlyAccess = (await KVStore.getValue('system.earlyAccess')) ?? false
      const githubUrl = earlyAccess
        ? 'https://api.github.com/repos/Crosstalk-Solutions/project-nomad/releases'
        : 'https://api.github.com/repos/Crosstalk-Solutions/project-nomad/releases/latest'
      const response = await axios.get(githubUrl, {
        headers: { Accept: 'application/vnd.github+json' },
        timeout: 5000,
      })
      const latestVersion = earlyAccess
        ? response.data?.[0]?.tag_name?.replace(/^v/, '').trim()
        : response.data?.tag_name?.replace(/^v/, '').trim()
      if (!latestVersion) {
        throw new Error('Invalid response from GitHub API')
      }

      const updateAvailable = process.env.NODE_ENV === 'development'
        ? false
        : isNewerVersion(latestVersion, currentVersion.trim(), earlyAccess)

      await KVStore.setValue('system.updateAvailable', updateAvailable)
      await KVStore.setValue('system.latestVersion', latestVersion)

      return {
        success: true,
        updateAvailable,
        currentVersion,
        latestVersion,
      }
    } catch (error) {
      logger.error('Error checking latest version:', error)
      return {
        success: false,
        updateAvailable: false,
        currentVersion: '',
        latestVersion: '',
        message: `Failed to check latest version: ${error instanceof Error ? error.message : error}`,
      }
    }
  }

  async subscribeToReleaseNotes(email: string): Promise<{ success: boolean; message: string }> {
    try {
      const response = await axios.post(
        'https://api.projectnomad.us/api/v1/lists/release-notes/subscribe',
        { email },
        { timeout: 5000 }
      )

      if (response.status === 200) {
        return { success: true, message: 'Successfully subscribed to release notes' }
      }

      return {
        success: false,
        message: `Failed to subscribe: ${response.statusText}`,
      }
    } catch (error) {
      logger.error('Error subscribing to release notes:', error)
      return {
        success: false,
        message: `Failed to subscribe: ${error instanceof Error ? error.message : error}`,
      }
    }
  }

  async getDebugInfo(): Promise<string> {
    const appVersion = SystemService.getAppVersion()
    const environment = process.env.NODE_ENV || 'unknown'
    const [systemInfo, services, internetStatus, versionCheck] = await Promise.all([
      this.getSystemInfo(),
      this.getServices({ installedOnly: false }),
      this.getInternetStatus().catch(() => null),
      this.checkLatestVersion().catch(() => null),
    ])

    const lines: string[] = [
      'RoachNet Debug Info',
      '===================',
      `App Version: ${appVersion}`,
      `Environment: ${environment}`,
    ]

    if (systemInfo) {
      lines.push('', 'System:')
      if (systemInfo.os.distro) lines.push(`  OS: ${systemInfo.os.distro}`)
      if (systemInfo.os.hostname) lines.push(`  Hostname: ${systemInfo.os.hostname}`)
      if (systemInfo.os.kernel) lines.push(`  Kernel: ${systemInfo.os.kernel}`)
      if (systemInfo.os.arch) lines.push(`  Architecture: ${systemInfo.os.arch}`)
      if (systemInfo.uptime?.uptime) lines.push(`  Uptime: ${this.formatUptime(systemInfo.uptime.uptime)}`)
      lines.push('', 'Hardware:')
      if (systemInfo.cpu.brand) lines.push(`  CPU: ${systemInfo.cpu.brand} (${systemInfo.cpu.cores} cores)`)
      if (systemInfo.mem.total) {
        lines.push(
          `  RAM: ${this.formatBytes(systemInfo.mem.total)} total, ${this.formatBytes(systemInfo.mem.total - (systemInfo.mem.available || 0))} used, ${this.formatBytes(systemInfo.mem.available || 0)} available`
        )
      }
      if (systemInfo.graphics.controllers.length > 0) {
        for (const gpu of systemInfo.graphics.controllers) {
          lines.push(`  GPU: ${gpu.model}${gpu.vram ? ` (${gpu.vram} MB VRAM)` : ''}`)
        }
      } else {
        lines.push('  GPU: None detected')
      }
    }

    const installed = services.filter((service) => service.installed)
    lines.push('', installed.length > 0 ? 'Installed Services:' : 'Installed Services: None')
    for (const service of installed) {
      lines.push(`  ${service.friendly_name} (${service.service_name}): ${service.status}`)
    }

    if (internetStatus !== null) {
      lines.push('', `Internet Status: ${internetStatus ? 'Online' : 'Offline'}`)
    }

    if (versionCheck?.success) {
      lines.push(
        `Update Available: ${versionCheck.updateAvailable ? `Yes (${versionCheck.latestVersion} available)` : `No (${versionCheck.currentVersion} is latest)`}`
      )
    }

    return lines.join('\n')
  }

  async updateSetting(key: KVStoreKey, value: any): Promise<void> {
    if ((value === '' || value === undefined || value === null) && KV_STORE_SCHEMA[key] === 'string') {
      await KVStore.clearValue(key)
    } else {
      await KVStore.setValue(key, value)
    }
  }

  private async buildServicesSnapshot(): Promise<ServiceSlim[]> {
    const statuses = await this.withTimeout(
      'docker service status',
      () => this.dockerService.getServicesStatus(),
      [] as Array<{ service_name: string; status: string }>,
      2000
    )

    await this.syncContainersWithDatabase(statuses)

    const services = await Service.query()
      .orderBy('display_order', 'asc')
      .orderBy('friendly_name', 'asc')
      .select(
        'id',
        'service_name',
        'installed',
        'installation_status',
        'ui_location',
        'friendly_name',
        'description',
        'icon',
        'powered_by',
        'display_order',
        'container_image',
        'available_update_version'
      )
      .where('is_dependency_service', false)

    const launcherManagedOllama =
      process.env.ROACHNET_NATIVE_ONLY === '1' &&
      process.env.OLLAMA_BASE_URL?.includes(':36434') === true

    return services.map((service) => {
      const branded = this.getBrandedServiceMetadata(service.service_name)
      const status = statuses.find((entry) => entry.service_name === service.service_name)
      const isLauncherManagedOllama =
        launcherManagedOllama && service.service_name === SERVICE_NAMES.OLLAMA

      return {
        id: service.id,
        service_name: service.service_name,
        friendly_name: branded.friendly_name ?? service.friendly_name,
        description: branded.description ?? service.description,
        icon: service.icon,
        installed: isLauncherManagedOllama || Boolean(service.installed),
        installation_status: service.installation_status,
        status: isLauncherManagedOllama ? 'running' : status ? status.status : 'unknown',
        ui_location: service.ui_location || '',
        powered_by: branded.powered_by ?? service.powered_by,
        display_order: service.display_order,
        container_image: service.container_image,
        available_update_version: service.available_update_version,
      }
    })
  }

  private filterServices(services: ServiceSlim[], installedOnly: boolean): ServiceSlim[] {
    return installedOnly ? services.filter((service) => service.installed) : services
  }

  private getBrandedServiceMetadata(serviceName: string): Partial<ServiceSlim> {
    switch (serviceName) {
      case SERVICE_NAMES.KIWIX:
        return {
          friendly_name: 'RoachNet Library',
          description: 'Offline encyclopedias, field manuals, and reference archives staged inside RoachNet.',
          powered_by: 'Kiwix',
        }
      case SERVICE_NAMES.OLLAMA:
        return {
          friendly_name: 'RoachNet Chat',
          description: 'Local AI chat and model tooling managed from the RoachNet command grid.',
          powered_by: 'Ollama',
        }
      case SERVICE_NAMES.CYBERCHEF:
        return {
          friendly_name: 'RoachNet Data Lab',
          description: 'Encoding, decoding, and analysis tools adapted for RoachNet field workflows.',
          powered_by: 'CyberChef + Jam',
        }
      case SERVICE_NAMES.FLATNOTES:
        return {
          friendly_name: 'RoachNet Notes',
          description: 'Fast local notes for fragments, checklists, and working references on the same machine.',
          powered_by: 'FlatNotes',
        }
      case SERVICE_NAMES.KOLIBRI:
        return {
          friendly_name: 'RoachNet Academy',
          description: 'Structured offline education content and coursework surfaced through RoachNet.',
          powered_by: 'Kolibri',
        }
      default:
        return {}
    }
  }

  private async syncContainersWithDatabase(serviceStatusList: Array<{ service_name: string; status: string }>) {
    try {
      const allServices = await Service.all()
      const repairTargets: Service[] = []
      const pendingSaves: Promise<unknown>[] = []

      for (const service of allServices) {
        const containerExists = serviceStatusList.find((entry) => entry.service_name === service.service_name)
        if (service.installed && !containerExists) {
          service.installed = false
          service.installation_status = 'idle'
          pendingSaves.push(service.save())
        } else if (!service.installed && containerExists) {
          service.installed = true
          service.installation_status = 'idle'
          pendingSaves.push(service.save())
        }

        if (containerExists && service.installed) {
          repairTargets.push(service)
        }
      }

      if (pendingSaves.length > 0) {
        await Promise.allSettled(pendingSaves)
      }

      this.scheduleLegacyRepairSweep(repairTargets)
    } catch (error) {
      logger.error('Error syncing containers with database:', error)
    }
  }

  private scheduleLegacyRepairSweep(services: Service[]) {
    if (services.length === 0 || SystemService.repairSweepPromise) {
      return
    }

    SystemService.repairSweepPromise = (async () => {
      for (const service of services) {
        await this.dockerService.repairLegacyContainerIfNeeded(service)
      }
    })().finally(() => {
      SystemService.repairSweepPromise = null
    })
  }

  private formatUptime(seconds: number): string {
    const days = Math.floor(seconds / 86400)
    const hours = Math.floor((seconds % 86400) / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    if (days > 0) return `${days}d ${hours}h ${minutes}m`
    if (hours > 0) return `${hours}h ${minutes}m`
    return `${minutes}m`
  }

  private formatBytes(bytes: number, decimals = 1): string {
    if (bytes === 0) return '0 Bytes'
    const k = 1024
    const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB']
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return `${parseFloat((bytes / Math.pow(k, i)).toFixed(decimals))} ${sizes[i]}`
  }

  private calculateDiskUsage(diskInfo: NomadDiskInfoRaw): NomadDiskInfo[] {
    const { diskLayout, fsSize } = diskInfo
    if (!diskLayout?.blockdevices || !fsSize) {
      return []
    }

    const deduped = new Map<string, NomadDiskInfoRaw['fsSize'][0]>()
    for (const entry of fsSize) {
      const existing = deduped.get(entry.fs)
      if (!existing || entry.size > existing.size) {
        deduped.set(entry.fs, entry)
      }
    }

    return diskLayout.blockdevices
      .filter((disk) => disk.type === 'disk')
      .map((disk) => {
        const filesystems = getAllFilesystems(disk, Array.from(deduped.values()))
        const totalUsed = filesystems.reduce((sum, filesystem) => sum + (filesystem.used || 0), 0)
        const totalSize = filesystems.reduce((sum, filesystem) => sum + (filesystem.size || 0), 0)
        return {
          name: disk.name,
          model: disk.model || 'Unknown',
          vendor: disk.vendor || 'Unknown',
          rota: Boolean(disk.rota),
          tran: disk.tran || '',
          size: disk.size || `${Math.round(totalSize / (1024 * 1024 * 1024))}G`,
          totalUsed,
          totalSize,
          percentUsed: totalSize > 0 ? (totalUsed / totalSize) * 100 : 0,
          filesystems: filesystems.map((filesystem) => ({
            fs: filesystem.fs,
            mount: filesystem.mount,
            used: filesystem.used || 0,
            size: filesystem.size || 0,
            percentUsed: filesystem.size > 0 ? ((filesystem.used || 0) / filesystem.size) * 100 : 0,
          })),
        }
      })
  }

  private getInternetTestUrl(): string {
    const customTestUrl = env.get('INTERNET_STATUS_TEST_URL')?.trim()
    if (!customTestUrl) {
      return 'https://1.1.1.1/cdn-cgi/trace'
    }

    try {
      new URL(customTestUrl)
      return customTestUrl
    } catch {
      logger.warn(`Invalid INTERNET_STATUS_TEST_URL: ${customTestUrl}. Falling back to default URL.`)
      return 'https://1.1.1.1/cdn-cgi/trace'
    }
  }

  private async withTimeout<T>(label: string, operation: () => Promise<T>, fallback: T, timeoutMs: number): Promise<T> {
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined
    try {
      return await Promise.race([
        operation(),
        new Promise<T>((resolve) => {
          timeoutHandle = setTimeout(() => {
            logger.warn(`[SystemService] Timed out while resolving ${label}; using fallback.`)
            resolve(fallback)
          }, timeoutMs)
        }),
      ])
    } catch (error) {
      logger.warn(
        `[SystemService] Failed while resolving ${label}; using fallback: ${error instanceof Error ? error.message : error}`
      )
      return fallback
    } finally {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }
    }
  }
}
