import Service from '#models/service'
import InstalledResource from '#models/installed_resource'
import Docker from 'dockerode'
import logger from '@adonisjs/core/services/logger'
import { inject } from '@adonisjs/core'
import { doResumableDownloadWithRetry } from '../utils/downloads.js'
import { basename, resolve } from 'path'
import { ZIM_STORAGE_PATH, getStorageRoot, resolveStoragePath } from '../utils/fs.js'
import { SERVICE_NAMES } from '../../constants/service_names.js'
import { exec } from 'child_process'
import { promisify } from 'util'
import { existsSync } from 'fs'
import { readdir } from 'fs/promises'
import { homedir } from 'os'
// import { readdir } from 'fs/promises'
import KVStore from '#models/kv_store'
import { BROADCAST_CHANNELS } from '../../constants/broadcast.js'
import { getErrorMessage } from '../utils/errors.js'
import { broadcastTransmit } from '#services/transmit_bridge'

@inject()
export class DockerService {
  public docker: Docker
  private activeInstallations: Set<string> = new Set()
  public static FALLBACK_ROACHNET_NETWORK = 'roachnet_default'
  private static GPU_CACHE_TTL_MS = 24 * 60 * 60 * 1000
  private static GPU_NONE_INVALIDATION_THRESHOLD = 3

  constructor() {
    this.docker = new Docker(this.resolveDockerConnectionOptions())
  }

  private resolveDockerConnectionOptions(): Docker.DockerOptions {
    const dockerHost = process.env.DOCKER_HOST?.trim()
    if (dockerHost) {
      if (dockerHost.startsWith('unix://')) {
        return { socketPath: dockerHost.replace('unix://', '') }
      }

      if (dockerHost.startsWith('npipe://')) {
        return { socketPath: dockerHost.replace('npipe://', '') }
      }

      try {
        const url = new URL(dockerHost)
        const normalizedProtocol = url.protocol.replace(':', '')
        const protocol =
          normalizedProtocol === 'https' || normalizedProtocol === 'ssh'
            ? normalizedProtocol
            : 'http'
        return {
          host: url.hostname,
          port: url.port ? Number(url.port) : protocol === 'https' ? 443 : 2375,
          protocol,
        }
      } catch {
        logger.warn(`[DockerService] Ignoring invalid DOCKER_HOST value: ${dockerHost}`)
      }
    }

    if (process.platform === 'win32') {
      return { socketPath: '//./pipe/docker_engine' }
    }

    const socketCandidates = [
      process.env.ROACHNET_DOCKER_SOCKET?.trim(),
      `${homedir()}/.docker/run/docker.sock`,
      `${homedir()}/.colima/default/docker.sock`,
      '/var/run/docker.sock',
    ].filter((candidate): candidate is string => Boolean(candidate && candidate.trim()))

    const socketPath = socketCandidates.find((candidate) => existsSync(candidate))
    return { socketPath: socketPath ?? '/var/run/docker.sock' }
  }

  private shouldUseManagedDockerNetwork(): boolean {
    return process.env.ROACHNET_USE_DOCKER === '1' || process.env.ROACHNET_RUNTIME_TARGET === 'docker'
  }

  private getManagedDockerNetworkName(): string {
    const explicitNetwork = process.env.ROACHNET_MANAGED_DOCKER_NETWORK?.trim()
    if (explicitNetwork) {
      return explicitNetwork
    }

    const composeProjectName = process.env.ROACHNET_COMPOSE_PROJECT_NAME?.trim()
    if (composeProjectName) {
      return `${composeProjectName}_default`
    }

    return DockerService.FALLBACK_ROACHNET_NETWORK
  }

  private getHostStorageRoot(): string {
    return process.env.ROACHNET_HOST_STORAGE_PATH?.trim() || getStorageRoot()
  }

  async affectContainer(
    serviceName: string,
    action: 'start' | 'stop' | 'restart'
  ): Promise<{ success: boolean; message: string }> {
    try {
      const service = await Service.query().where('service_name', serviceName).first()
      if (!service || !service.installed) {
        return {
          success: false,
          message: `Service ${serviceName} not found or not installed`,
        }
      }

      const containers = await this.docker.listContainers({ all: true })
      const container = containers.find((c) => c.Names.includes(`/${serviceName}`))
      if (!container) {
        return {
          success: false,
          message: `Container for service ${serviceName} not found`,
        }
      }

      const dockerContainer = this.docker.getContainer(container.Id)
      if (action === 'stop') {
        await dockerContainer.stop()
        return {
          success: true,
          message: `Service ${serviceName} stopped successfully`,
        }
      }

      if (action === 'restart') {
        await dockerContainer.restart()

        return {
          success: true,
          message: `Service ${serviceName} restarted successfully`,
        }
      }

      if (action === 'start') {
        if (container.State === 'running') {
          return {
            success: true,
            message: `Service ${serviceName} is already running`,
          }
        }

        await dockerContainer.start()

        return {
          success: true,
          message: `Service ${serviceName} started successfully`,
        }
      }

      return {
        success: false,
        message: `Invalid action: ${action}. Use 'start', 'stop', or 'restart'.`,
      }
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      logger.error(`Error starting service ${serviceName}: ${errorMessage}`)
      return {
        success: false,
        message: `Failed to start service ${serviceName}: ${errorMessage}`,
      }
    }
  }

  /**
   * Fetches the status of all Docker containers related to RoachNet services. (those prefixed with 'roachnet_')
   */
  async getServicesStatus(): Promise<
    {
      service_name: string
      status: string
    }[]
  > {
    try {
      const containers = await this.docker.listContainers({ all: true })
      const containerMap = new Map<string, Docker.ContainerInfo>()
      containers.forEach((container) => {
        const name = container.Names[0]?.replace('/', '')
        if (name && name.startsWith('roachnet_')) {
          containerMap.set(name, container)
        }
      })

      return Array.from(containerMap.entries()).map(([name, container]) => ({
        service_name: name,
        status: container.State,
      }))
    } catch (error) {
      logger.error(`Error fetching services status: ${getErrorMessage(error)}`)
      return []
    }
  }

  /**
   * Get the URL to access a service based on its configuration.
   * Attempts to return a docker-internal URL using the service name and exposed port.
   * @param serviceName - The name of the service to get the URL for.
   * @returns - The URL as a string, or null if it cannot be determined.
   */
  async getServiceURL(serviceName: string): Promise<string | null> {
    if (!serviceName || serviceName.trim() === '') {
      return null
    }

    const nativeOverrides: Record<string, string | undefined> = {
      [SERVICE_NAMES.OLLAMA]: process.env.OLLAMA_BASE_URL?.trim(),
      [SERVICE_NAMES.QDRANT]: process.env.QDRANT_URL?.trim(),
    }
    const nativeOverride = nativeOverrides[serviceName]
    if (nativeOverride) {
      return nativeOverride
    }

    const service = await Service.query()
      .where('service_name', serviceName)
      .andWhere('installed', true)
      .first()

    if (!service) {
      return null
    }

    const hostname = this.shouldUseManagedDockerNetwork() ? serviceName : 'localhost'

    // First, check if ui_location is set and is a valid port number
    if (service.ui_location && parseInt(service.ui_location, 10)) {
      return `http://${hostname}:${service.ui_location}`
    }

    // Next, try to extract a host port from container_config
    const parsedConfig = this._parseContainerConfig(service.container_config)
    if (parsedConfig?.HostConfig?.PortBindings) {
      const portBindings = parsedConfig.HostConfig.PortBindings
      const hostPorts = Object.values(portBindings)
      if (!hostPorts || !Array.isArray(hostPorts) || hostPorts.length === 0) {
        return null
      }

      const hostPortsArray = hostPorts.flat() as { HostPort: string }[]
      const hostPortsStrings = hostPortsArray.map((binding) => binding.HostPort)
      if (hostPortsStrings.length > 0) {
        return `http://${hostname}:${hostPortsStrings[0]}`
      }
    }

    // Otherwise, return null if we can't determine a URL
    return null
  }

  async createContainerPreflight(
    serviceName: string
  ): Promise<{ success: boolean; message: string }> {
    const service = await Service.query().where('service_name', serviceName).first()
    if (!service) {
      return {
        success: false,
        message: `Service ${serviceName} not found`,
      }
    }

    if (service.installed) {
      return {
        success: false,
        message: `Service ${serviceName} is already installed`,
      }
    }

    // Check if installation is already in progress (database-level)
    if (service.installation_status === 'installing') {
      return {
        success: false,
        message: `Service ${serviceName} installation is already in progress`,
      }
    }

    // Double-check with in-memory tracking (race condition protection)
    if (this.activeInstallations.has(serviceName)) {
      return {
        success: false,
        message: `Service ${serviceName} installation is already in progress`,
      }
    }

    // Mark installation as in progress
    this.activeInstallations.add(serviceName)
    service.installation_status = 'installing'
    await service.save()

    // Check if a service wasn't marked as installed but has an existing container
    // This can happen if the service was created but not properly installed
    // or if the container was removed manually without updating the service status.
    // if (await this._checkIfServiceContainerExists(serviceName)) {
    //   const removeResult = await this._removeServiceContainer(serviceName);
    //   if (!removeResult.success) {
    //     return {
    //       success: false,
    //       message: `Failed to remove existing container for service ${serviceName}: ${removeResult.message}`,
    //     };
    //   }
    // }

    const containerConfig = this._parseContainerConfig(service.container_config)

    // Execute installation asynchronously and handle cleanup
    this._createContainer(service, containerConfig).catch(async (error) => {
      logger.error(`Installation failed for ${serviceName}: ${getErrorMessage(error)}`)
      await this._cleanupFailedInstallation(serviceName)
    })

    return {
      success: true,
      message: `Service ${serviceName} installation initiated successfully. You can receive updates via server-sent events.`,
    }
  }

  /**
   * Force reinstall a service by stopping, removing, and recreating its container.
   * This method will also clear any associated volumes/data.
   * Handles edge cases gracefully (e.g., container not running, container not found).
   */
  async forceReinstall(serviceName: string): Promise<{ success: boolean; message: string }> {
    try {
      const service = await Service.query().where('service_name', serviceName).first()
      if (!service) {
        return {
          success: false,
          message: `Service ${serviceName} not found`,
        }
      }

      // Check if installation is already in progress
      if (this.activeInstallations.has(serviceName)) {
        return {
          success: false,
          message: `Service ${serviceName} installation is already in progress`,
        }
      }

      // Mark as installing to prevent concurrent operations
      this.activeInstallations.add(serviceName)
      service.installation_status = 'installing'
      await service.save()

      this._broadcast(
        serviceName,
        'reinstall-starting',
        `Starting force reinstall for ${serviceName}...`
      )

      // Step 1: Try to stop and remove the container if it exists
      try {
        const containers = await this.docker.listContainers({ all: true })
        const container = containers.find((c) => c.Names.includes(`/${serviceName}`))

        if (container) {
          const dockerContainer = this.docker.getContainer(container.Id)

          // Only try to stop if it's running
          if (container.State === 'running') {
            this._broadcast(serviceName, 'stopping', `Stopping container...`)
            await dockerContainer.stop({ t: 10 }).catch((error) => {
              // If already stopped, continue
              const errorMessage = getErrorMessage(error)
              if (!errorMessage.includes('already stopped')) {
                logger.warn(`Error stopping container: ${errorMessage}`)
              }
            })
          }

          // Step 2: Remove the container
          this._broadcast(serviceName, 'removing', `Removing container...`)
          await dockerContainer.remove({ force: true }).catch((error) => {
            logger.warn(`Error removing container: ${getErrorMessage(error)}`)
          })
        } else {
          this._broadcast(
            serviceName,
            'no-container',
            `No existing container found, proceeding with installation...`
          )
        }
      } catch (error) {
        const errorMessage = getErrorMessage(error)
        logger.warn(`Error during container cleanup: ${errorMessage}`)
        this._broadcast(serviceName, 'cleanup-warning', `Warning during cleanup: ${errorMessage}`)
      }

      // Step 3: Clear volumes/data if needed
      try {
        this._broadcast(serviceName, 'clearing-volumes', `Checking for volumes to clear...`)
        const volumes = await this.docker.listVolumes()
        const serviceVolumes =
          volumes.Volumes?.filter(
            (v) => v.Name.includes(serviceName) || v.Labels?.service === serviceName
          ) || []

        for (const vol of serviceVolumes) {
          try {
            const volume = this.docker.getVolume(vol.Name)
            await volume.remove({ force: true })
            this._broadcast(serviceName, 'volume-removed', `Removed volume: ${vol.Name}`)
          } catch (error) {
            logger.warn(`Failed to remove volume ${vol.Name}: ${getErrorMessage(error)}`)
          }
        }

        if (serviceVolumes.length === 0) {
          this._broadcast(serviceName, 'no-volumes', `No volumes found to clear`)
        }
      } catch (error) {
        const errorMessage = getErrorMessage(error)
        logger.warn(`Error during volume cleanup: ${errorMessage}`)
        this._broadcast(
          serviceName,
          'volume-cleanup-warning',
          `Warning during volume cleanup: ${errorMessage}`
        )
      }

      // Step 4: Mark service as uninstalled
      service.installed = false
      service.installation_status = 'installing'
      await service.save()

      // Step 5: Recreate the container
      this._broadcast(serviceName, 'recreating', `Recreating container...`)
      const containerConfig = this._parseContainerConfig(service.container_config)

      // Execute installation asynchronously and handle cleanup
      this._createContainer(service, containerConfig).catch(async (error) => {
        logger.error(`Reinstallation failed for ${serviceName}: ${getErrorMessage(error)}`)
        await this._cleanupFailedInstallation(serviceName)
      })

      return {
        success: true,
        message: `Service ${serviceName} force reinstall initiated successfully. You can receive updates via server-sent events.`,
      }
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      logger.error(`Force reinstall failed for ${serviceName}: ${errorMessage}`)
      await this._cleanupFailedInstallation(serviceName)
      return {
        success: false,
        message: `Failed to force reinstall service ${serviceName}: ${errorMessage}`,
      }
    }
  }

  /**
   * Handles the long-running process of creating a Docker container for a service.
   * NOTE: This method should not be called directly. Instead, use `createContainerPreflight` to check prerequisites first
   * This method will also transmit server-sent events to the client to notify of progress.
   * @param serviceName
   * @returns
   */
  async _createContainer(
    service: Service & { dependencies?: Service[] },
    containerConfig: any
  ): Promise<void> {
    try {
      this._broadcast(service.service_name, 'initializing', '')

      let dependencies = []
      if (service.depends_on) {
        const dependency = await Service.query().where('service_name', service.depends_on).first()
        if (dependency) {
          dependencies.push(dependency)
        }
      }

      // First, check if the service has any dependencies that need to be installed first
      if (dependencies && dependencies.length > 0) {
        this._broadcast(
          service.service_name,
          'checking-dependencies',
          `Checking dependencies for service ${service.service_name}...`
        )
        for (const dependency of dependencies) {
          if (!dependency.installed) {
            this._broadcast(
              service.service_name,
              'dependency-not-installed',
              `Dependency service ${dependency.service_name} is not installed. Installing it first...`
            )
            await this._installDependency(service.service_name, dependency)
          } else {
            this._broadcast(
              service.service_name,
              'dependency-installed',
              `Dependency service ${dependency.service_name} is already installed.`
            )
          }
        }
      }

      const imageExists = await this._checkImageExists(service.container_image)
      if (imageExists) {
        this._broadcast(
          service.service_name,
          'image-exists',
          `Docker image ${service.container_image} already exists locally. Skipping pull...`
        )
      } else {
        // Start pulling the Docker image and wait for it to complete
        const pullStream = await this.docker.pull(service.container_image)
        this._broadcast(
          service.service_name,
          'pulling',
          `Pulling Docker image ${service.container_image}...`
        )
        await new Promise((res) => this.docker.modem.followProgress(pullStream, res))
      }

      if (service.service_name === SERVICE_NAMES.KIWIX) {
        await this._runPreinstallActions__KiwixServe()
        this._broadcast(
          service.service_name,
          'preinstall-complete',
          `Pre-install actions for Kiwix Serve completed successfully.`
        )
      }

      // GPU-aware configuration for Ollama
      let finalImage = service.container_image
      let gpuHostConfig = containerConfig?.HostConfig || {}

      if (service.service_name === SERVICE_NAMES.OLLAMA) {
        const gpuResult = await this._detectGPUType()

        if (gpuResult.type === 'nvidia') {
          this._broadcast(
            service.service_name,
            'gpu-config',
            `NVIDIA container runtime detected. Configuring container with GPU support...`
          )

          // Add GPU support for NVIDIA
          gpuHostConfig = {
            ...gpuHostConfig,
            DeviceRequests: [
              {
                Driver: 'nvidia',
                Count: -1, // -1 means all GPUs
                Capabilities: [['gpu']],
              },
            ],
          }
        } else if (gpuResult.type === 'amd') {
          this._broadcast(
            service.service_name,
            'gpu-config',
            `AMD GPU detected. ROCm GPU acceleration is not yet supported in this version — proceeding with CPU-only configuration. GPU support for AMD will be available in a future update.`
          )
          logger.warn('[DockerService] AMD GPU detected but ROCm support is not yet enabled. Using CPU-only configuration.')
          // TODO: Re-enable AMD GPU support once ROCm image and device discovery are validated.
          // When re-enabling:
          //   1. Switch image to 'ollama/ollama:rocm'
          //   2. Restore _discoverAMDDevices() to map /dev/kfd and /dev/dri/* into the container
        } else if (gpuResult.toolkitMissing) {
          this._broadcast(
            service.service_name,
            'gpu-config',
            `NVIDIA GPU detected but NVIDIA Container Toolkit is not installed. Using CPU-only configuration. Install the toolkit and reinstall AI Assistant for GPU acceleration: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html`
          )
        } else {
          this._broadcast(
            service.service_name,
            'gpu-config',
            `No GPU detected. Using CPU-only configuration...`
          )
        }
      }

      this._broadcast(
        service.service_name,
        'creating',
        `Creating Docker container for service ${service.service_name}...`
      )
      const managedNetworkName = this.getManagedDockerNetworkName()
      logger.info(
        `[DockerService] [${service.service_name}] Preparing container with network=${managedNetworkName} image=${finalImage}`
      )
      const containerCmd =
        service.service_name === SERVICE_NAMES.KIWIX
          ? await this._buildKiwixCommand()
          : (service.container_command ? service.container_command.split(' ') : undefined)

      const container = await this.docker.createContainer({
        Image: finalImage,
        name: service.service_name,
        ...(containerConfig?.User && { User: containerConfig.User }),
        HostConfig: gpuHostConfig,
        ...(containerConfig?.WorkingDir && { WorkingDir: containerConfig.WorkingDir }),
        ...(containerConfig?.ExposedPorts && { ExposedPorts: containerConfig.ExposedPorts }),
        ...(containerConfig?.Env && { Env: containerConfig.Env }),
        ...(containerCmd ? { Cmd: containerCmd } : {}),
        // Only attach services to the managed compose network when the runtime explicitly
        // opted into the Docker orchestration path.
        ...(this.shouldUseManagedDockerNetwork() && {
          NetworkingConfig: {
            EndpointsConfig: {
              [managedNetworkName]: {},
            },
          },
        }),
      })

      this._broadcast(
        service.service_name,
        'starting',
        `Starting Docker container for service ${service.service_name}...`
      )
      await container.start()

      this._broadcast(
        service.service_name,
        'finalizing',
        `Finalizing installation of service ${service.service_name}...`
      )
      service.installed = true
      service.installation_status = 'idle'
      await service.save()

      // Remove from active installs tracking
      this.activeInstallations.delete(service.service_name)

      // If Ollama was just installed, trigger RoachNet docs discovery and embedding
      if (service.service_name === SERVICE_NAMES.OLLAMA) {
        logger.info('[DockerService] Ollama installation complete. Default behavior is to not enable chat suggestions.')
        await KVStore.setValue('chat.suggestionsEnabled', false)

        logger.info('[DockerService] Ollama installation complete. Triggering RoachNet docs discovery...')
        
        // Need to use dynamic imports here to avoid circular dependency
        const ollamaService = new (await import('./ollama_service.js')).OllamaService()
        const ragService = new (await import('./rag_service.js')).RagService(this, ollamaService)

        ragService.discoverRoachNetDocs().catch((error) => {
          logger.error('[DockerService] Failed to discover RoachNet docs:', error)
        })
      }

      this._broadcast(
        service.service_name,
        'completed',
        `Service ${service.service_name} installation completed successfully.`
      )
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      this._broadcast(
        service.service_name,
        'error',
        `Error installing service ${service.service_name}: ${errorMessage}`
      )
      // Mark install as failed and cleanup
      await this._cleanupFailedInstallation(service.service_name)
      throw new Error(`Failed to install service ${service.service_name}: ${errorMessage}`)
    }
  }

  private async _installDependency(
    parentServiceName: string,
    dependency: Service
  ): Promise<void> {
    const dependencyName = dependency.service_name
    const shouldTrackDependency = !this.activeInstallations.has(dependencyName)

    if (!shouldTrackDependency) {
      this._broadcast(
        parentServiceName,
        'dependency-pending',
        `Dependency service ${dependencyName} is already installing. Waiting for it to finish...`
      )
      await this._waitForDependencyInstallation(dependencyName)
      return
    }

    const dependencyConfig = this._parseContainerConfig(dependency.container_config)

    this.activeInstallations.add(dependencyName)
    dependency.installation_status = 'installing'
    await dependency.save()

    try {
      await this._createContainer(dependency, dependencyConfig)
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      logger.error(
        `[DockerService] Dependency installation failed for ${parentServiceName} -> ${dependencyName}: ${errorMessage}`
      )
      throw error
    } finally {
      if (this.activeInstallations.has(dependencyName) && !dependency.installed) {
        this.activeInstallations.delete(dependencyName)
      }
    }
  }

  private async _waitForDependencyInstallation(serviceName: string): Promise<void> {
    const deadline = Date.now() + 5 * 60 * 1000

    while (Date.now() < deadline) {
      const dependency = await Service.query().where('service_name', serviceName).first()
      if (!dependency) {
        throw new Error(`Dependency service ${serviceName} no longer exists.`)
      }

      if (dependency.installed) {
        return
      }

      if (dependency.installation_status === 'error') {
        throw new Error(`Dependency service ${serviceName} failed to install.`)
      }

      await new Promise((resolve) => setTimeout(resolve, 1000))
    }

    throw new Error(`Timed out waiting for dependency service ${serviceName} to install.`)
  }

  async _checkIfServiceContainerExists(serviceName: string): Promise<boolean> {
    try {
      const containers = await this.docker.listContainers({ all: true })
      return containers.some((container) => container.Names.includes(`/${serviceName}`))
    } catch (error) {
      logger.error(`Error checking if service container exists: ${getErrorMessage(error)}`)
      return false
    }
  }

  async _removeServiceContainer(
    serviceName: string
  ): Promise<{ success: boolean; message: string }> {
    try {
      const containers = await this.docker.listContainers({ all: true })
      const container = containers.find((c) => c.Names.includes(`/${serviceName}`))
      if (!container) {
        return { success: false, message: `Container for service ${serviceName} not found` }
      }

      const dockerContainer = this.docker.getContainer(container.Id)
      await dockerContainer.remove({ force: true })

      return { success: true, message: `Service ${serviceName} container removed successfully` }
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      logger.error(`Error removing service container: ${errorMessage}`)
      return {
        success: false,
        message: `Failed to remove service ${serviceName} container: ${errorMessage}`,
      }
    }
  }

  private async _runPreinstallActions__KiwixServe(): Promise<void> {
    /**
     * At least one .zim file must be available before we can start the kiwix container.
     * We'll download the lightweight mini Wikipedia Top 100 zim file for this purpose.
     **/
    const WIKIPEDIA_ZIM_URL =
      'https://github.com/AHGRoach/RoachNet/raw/refs/heads/main/install/wikipedia_en_100_mini_2026-01.zim'
    const filename = 'wikipedia_en_100_mini_2026-01.zim'
    const filepath = resolveStoragePath(ZIM_STORAGE_PATH, filename)
    logger.info(`[DockerService] Kiwix Serve pre-install: Downloading ZIM file to ${filepath}`)

    this._broadcast(
      SERVICE_NAMES.KIWIX,
      'preinstall',
      `Running pre-install actions for Kiwix Serve...`
    )
    this._broadcast(
      SERVICE_NAMES.KIWIX,
      'preinstall',
      `Downloading Wikipedia ZIM file from ${WIKIPEDIA_ZIM_URL}. This may take some time...`
    )

    try {
      await doResumableDownloadWithRetry({
        url: WIKIPEDIA_ZIM_URL,
        filepath,
        timeout: 60000,
        allowedMimeTypes: [
          'application/x-zim',
          'application/x-openzim',
          'application/octet-stream',
        ],
      })

      this._broadcast(
        SERVICE_NAMES.KIWIX,
        'preinstall',
        `Downloaded Wikipedia ZIM file to ${filepath}`
      )
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      this._broadcast(
        SERVICE_NAMES.KIWIX,
        'preinstall-error',
        `Failed to download Wikipedia ZIM file: ${errorMessage}`
      )
      throw new Error(`Pre-install action failed: ${errorMessage}`)
    }
  }

  private async _buildKiwixCommand(): Promise<string[]> {
    const installedEntries = await InstalledResource.query().where('resource_type', 'zim').orderBy('installed_at', 'asc')

    const filenames = Array.from(
      new Set(
        installedEntries
          .map((entry) => entry.file_path)
          .filter((filePath): filePath is string => Boolean(filePath))
          .map((filePath) => basename(filePath))
      )
    )

    if (filenames.length === 0) {
      try {
        const directoryEntries = await readdir(resolveStoragePath(ZIM_STORAGE_PATH), {
          withFileTypes: true,
        })

        for (const entry of directoryEntries) {
          if (entry.isFile() && entry.name.endsWith('.zim')) {
            filenames.push(entry.name)
          }
        }
      } catch (error) {
        logger.warn(
          `[DockerService] Failed to inspect ZIM storage for Kiwix startup: ${getErrorMessage(error)}`
        )
      }
    }

    if (filenames.length === 0) {
      filenames.push('wikipedia_en_100_mini_2026-01.zim')
    }

    return ['--skipInvalid', ...Array.from(new Set(filenames)), '--address=all']
  }

  private async _cleanupFailedInstallation(serviceName: string): Promise<void> {
    try {
      const service = await Service.query().where('service_name', serviceName).first()
      if (service) {
        service.installation_status = 'error'
        await service.save()
      }
      this.activeInstallations.delete(serviceName)

      // Ensure any partially created container is removed
      await this._removeServiceContainer(serviceName)

      logger.info(`[DockerService] Cleaned up failed installation for ${serviceName}`)
    } catch (error) {
      logger.error(
        `[DockerService] Failed to cleanup installation for ${serviceName}: ${getErrorMessage(error)}`
      )
    }
  }

  /**
   * Detect GPU type and toolkit availability.
   * Primary: Check Docker runtimes via docker.info() (works from inside containers).
   * Fallback: lspci for host-based installs and AMD detection.
   */
  private async _detectGPUType(): Promise<{ type: 'nvidia' | 'amd' | 'none'; toolkitMissing?: boolean }> {
    try {
      let completedLiveGpuProbe = false

      // Primary: Check Docker daemon for nvidia runtime (works from inside containers)
      try {
        const dockerInfo = await this.docker.info()
        const runtimes = dockerInfo.Runtimes || {}
        if ('nvidia' in runtimes) {
          logger.info('[DockerService] NVIDIA container runtime detected via Docker API')
          await this._persistGPUType('nvidia')
          return { type: 'nvidia' }
        }
      } catch (error) {
        logger.warn(
          `[DockerService] Could not query Docker info for GPU runtimes: ${getErrorMessage(error)}`
        )
      }

      // Fallback: lspci for host-based installs (not available inside Docker)
      const execAsync = promisify(exec)

      // Check for NVIDIA GPU via lspci
      try {
        const { stdout: nvidiaCheck } = await execAsync(
          'lspci 2>/dev/null | grep -i nvidia || true'
        )
        completedLiveGpuProbe = true
        if (nvidiaCheck.trim()) {
          // GPU hardware found but no nvidia runtime — toolkit not installed
          logger.warn('[DockerService] NVIDIA GPU detected via lspci but NVIDIA Container Toolkit is not installed')
          return { type: 'none', toolkitMissing: true }
        }
      } catch (error) {
        // lspci not available (likely inside Docker container), continue
      }

      // Check for AMD GPU via lspci — restrict to display controller classes to avoid
      // false positives from AMD CPU host bridges, PCI bridges, and chipset devices.
      try {
        const { stdout: amdCheck } = await execAsync(
          'lspci 2>/dev/null | grep -iE "VGA|3D controller|Display" | grep -iE "amd|radeon" || true'
        )
        completedLiveGpuProbe = true
        if (amdCheck.trim()) {
          logger.info('[DockerService] AMD GPU detected via lspci')
          await this._persistGPUType('amd')
          return { type: 'amd' }
        }
      } catch (error) {
        // lspci not available, continue
      }

      // Last resort: check if we previously detected a GPU and it's likely still present.
      // This handles cases where live detection fails transiently (e.g., Docker daemon
      // hiccup, runtime temporarily unavailable) but the hardware hasn't changed.
      const cachedType = await this._getPersistedGPUType()
      if (cachedType) {
        logger.info(
          `[DockerService] No GPU detected live, but KV store has a fresh '${cachedType}' detection. Using saved value.`
        )
        return { type: cachedType }
      }

      if (completedLiveGpuProbe) {
        await this._recordNoGPUDetection()
      }

      logger.info('[DockerService] No GPU detected')
      return { type: 'none' }
    } catch (error) {
      logger.warn(`[DockerService] Error detecting GPU type: ${getErrorMessage(error)}`)
      return { type: 'none' }
    }
  }

  private async _persistGPUType(type: 'nvidia' | 'amd'): Promise<void> {
    try {
      await Promise.all([
        KVStore.setValue('gpu.type', type),
        KVStore.setValue('gpu.detectedAt', new Date().toISOString()),
        KVStore.setValue('gpu.noneDetectionCount', '0'),
      ])
      logger.info(`[DockerService] Persisted GPU type '${type}' to KV store`)
    } catch (error) {
      logger.warn(`[DockerService] Failed to persist GPU type: ${getErrorMessage(error)}`)
    }
  }

  private async _getPersistedGPUType(): Promise<'nvidia' | 'amd' | null> {
    try {
      const [savedType, detectedAtRaw, noneDetectionCountRaw] = await Promise.all([
        KVStore.getValue('gpu.type'),
        KVStore.getValue('gpu.detectedAt'),
        KVStore.getValue('gpu.noneDetectionCount'),
      ])

      if (savedType !== 'nvidia' && savedType !== 'amd') {
        return null
      }

      const detectedAt = detectedAtRaw ? Date.parse(detectedAtRaw) : Number.NaN
      const noneDetectionCount = Number.parseInt(noneDetectionCountRaw || '0', 10) || 0

      if (
        Number.isNaN(detectedAt) ||
        Date.now() - detectedAt > DockerService.GPU_CACHE_TTL_MS ||
        noneDetectionCount >= DockerService.GPU_NONE_INVALIDATION_THRESHOLD
      ) {
        await this._clearPersistedGPUType()
        return null
      }

      return savedType
    } catch {
      return null
    }
  }

  private async _recordNoGPUDetection(): Promise<void> {
    try {
      const currentCount = Number.parseInt((await KVStore.getValue('gpu.noneDetectionCount')) || '0', 10) || 0
      const nextCount = currentCount + 1

      await KVStore.setValue('gpu.noneDetectionCount', String(nextCount))

      if (nextCount >= DockerService.GPU_NONE_INVALIDATION_THRESHOLD) {
        await this._clearPersistedGPUType()
      }
    } catch (error) {
      logger.warn(`[DockerService] Failed to record a no-GPU detection: ${getErrorMessage(error)}`)
    }
  }

  private async _clearPersistedGPUType(): Promise<void> {
    try {
      await Promise.all([
        KVStore.clearValue('gpu.type'),
        KVStore.clearValue('gpu.detectedAt'),
        KVStore.clearValue('gpu.noneDetectionCount'),
      ])
    } catch (error) {
      logger.warn(`[DockerService] Failed to clear cached GPU type: ${getErrorMessage(error)}`)
    }
  }

  /**
   * Discover AMD GPU DRI devices dynamically.
   * Returns an array of device configurations for Docker.
   */
  // private async _discoverAMDDevices(): Promise<
  //   Array<{ PathOnHost: string; PathInContainer: string; CgroupPermissions: string }>
  // > {
  //   try {
  //     const devices: Array<{
  //       PathOnHost: string
  //       PathInContainer: string
  //       CgroupPermissions: string
  //     }> = []

  //     // Always add /dev/kfd (Kernel Fusion Driver)
  //     devices.push({
  //       PathOnHost: '/dev/kfd',
  //       PathInContainer: '/dev/kfd',
  //       CgroupPermissions: 'rwm',
  //     })

  //     // Discover DRI devices in /dev/dri/
  //     try {
  //       const driDevices = await readdir('/dev/dri')
  //       for (const device of driDevices) {
  //         const devicePath = `/dev/dri/${device}`
  //         devices.push({
  //           PathOnHost: devicePath,
  //           PathInContainer: devicePath,
  //           CgroupPermissions: 'rwm',
  //         })
  //       }
  //       logger.info(
  //         `[DockerService] Discovered ${driDevices.length} DRI devices: ${driDevices.join(', ')}`
  //       )
  //     } catch (error) {
  //       logger.warn(`[DockerService] Could not read /dev/dri directory: ${error.message}`)
  //       // Fallback to common device names if directory read fails
  //       const fallbackDevices = ['card0', 'renderD128']
  //       for (const device of fallbackDevices) {
  //         devices.push({
  //           PathOnHost: `/dev/dri/${device}`,
  //           PathInContainer: `/dev/dri/${device}`,
  //           CgroupPermissions: 'rwm',
  //         })
  //       }
  //       logger.info(`[DockerService] Using fallback DRI devices: ${fallbackDevices.join(', ')}`)
  //     }

  //     return devices
  //   } catch (error) {
  //     logger.error(`[DockerService] Error discovering AMD devices: ${error.message}`)
  //     return []
  //   }
  // }

  /**
   * Update a service container to a new image version while preserving volumes and data.
   * Includes automatic rollback if the new container fails health checks.
   */
  async updateContainer(
    serviceName: string,
    targetVersion: string
  ): Promise<{ success: boolean; message: string }> {
    try {
      const service = await Service.query().where('service_name', serviceName).first()
      if (!service) {
        return { success: false, message: `Service ${serviceName} not found` }
      }
      if (!service.installed) {
        return { success: false, message: `Service ${serviceName} is not installed` }
      }
      if (this.activeInstallations.has(serviceName)) {
        return { success: false, message: `Service ${serviceName} already has an operation in progress` }
      }

      this.activeInstallations.add(serviceName)

      // Compute new image string
      const currentImage = service.container_image
      const imageBase = currentImage.includes(':')
        ? currentImage.substring(0, currentImage.lastIndexOf(':'))
        : currentImage
      const newImage = `${imageBase}:${targetVersion}`

      // Step 1: Pull new image
      this._broadcast(serviceName, 'update-pulling', `Pulling image ${newImage}...`)
      const pullStream = await this.docker.pull(newImage)
      await new Promise((res) => this.docker.modem.followProgress(pullStream, res))

      // Step 2: Find and stop existing container
      this._broadcast(serviceName, 'update-stopping', `Stopping current container...`)
      const containers = await this.docker.listContainers({ all: true })
      const existingContainer = containers.find((c) => c.Names.includes(`/${serviceName}`))

      if (!existingContainer) {
        this.activeInstallations.delete(serviceName)
        return { success: false, message: `Container for ${serviceName} not found` }
      }

      const oldContainer = this.docker.getContainer(existingContainer.Id)

      // Inspect to capture full config before stopping
      const inspectData = await oldContainer.inspect()

      if (existingContainer.State === 'running') {
        await oldContainer.stop({ t: 15 })
      }

      // Step 3: Rename old container as safety net
      const oldName = `${serviceName}_old`
      await oldContainer.rename({ name: oldName })

      // Step 4: Create new container with inspected config + new image
      this._broadcast(serviceName, 'update-creating', `Creating updated container...`)

      const hostConfig = inspectData.HostConfig || {}

      // Re-run GPU detection for Ollama so updates always reflect the current GPU environment.
      // This handles cases where the NVIDIA Container Toolkit was installed after the initial
      // Ollama setup, and ensures DeviceRequests are always built fresh rather than relying on
      // round-tripping the Docker inspect format back into the create API.
      let updatedDeviceRequests: any[] | undefined = undefined
      if (serviceName === SERVICE_NAMES.OLLAMA) {
        const gpuResult = await this._detectGPUType()

        if (gpuResult.type === 'nvidia') {
          this._broadcast(
            serviceName,
            'update-gpu-config',
            `NVIDIA container runtime detected. Configuring updated container with GPU support...`
          )
          updatedDeviceRequests = [
            {
              Driver: 'nvidia',
              Count: -1,
              Capabilities: [['gpu']],
            },
          ]
        } else if (gpuResult.type === 'amd') {
          this._broadcast(
            serviceName,
            'update-gpu-config',
            `AMD GPU detected. ROCm GPU acceleration is not yet supported — using CPU-only configuration.`
          )
        } else if (gpuResult.toolkitMissing) {
          this._broadcast(
            serviceName,
            'update-gpu-config',
            `NVIDIA GPU detected but NVIDIA Container Toolkit is not installed. Using CPU-only configuration. Install the toolkit and reinstall AI Assistant for GPU acceleration: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html`
          )
        } else {
          this._broadcast(serviceName, 'update-gpu-config', `No GPU detected. Using CPU-only configuration.`)
        }
      }

      const newContainerConfig: any = {
        Image: newImage,
        name: serviceName,
        Env: inspectData.Config?.Env || undefined,
        Cmd: inspectData.Config?.Cmd || undefined,
        ExposedPorts: inspectData.Config?.ExposedPorts || undefined,
        WorkingDir: inspectData.Config?.WorkingDir || undefined,
        User: inspectData.Config?.User || undefined,
        HostConfig: {
          Binds: hostConfig.Binds || undefined,
          PortBindings: hostConfig.PortBindings || undefined,
          RestartPolicy: hostConfig.RestartPolicy || undefined,
          DeviceRequests: serviceName === SERVICE_NAMES.OLLAMA ? updatedDeviceRequests : (hostConfig.DeviceRequests || undefined),
          Devices: hostConfig.Devices || undefined,
        },
        NetworkingConfig: inspectData.NetworkSettings?.Networks
          ? {
              EndpointsConfig: Object.fromEntries(
                Object.keys(inspectData.NetworkSettings.Networks).map((net) => [net, {}])
              ),
            }
          : undefined,
      }

      // Remove undefined values from HostConfig
      Object.keys(newContainerConfig.HostConfig).forEach((key) => {
        if (newContainerConfig.HostConfig[key] === undefined) {
          delete newContainerConfig.HostConfig[key]
        }
      })

      let newContainer: any
      try {
        newContainer = await this.docker.createContainer(newContainerConfig)
      } catch (createError) {
        // Rollback: rename old container back
        const createErrorMessage = getErrorMessage(createError)
        this._broadcast(serviceName, 'update-rollback', `Failed to create new container: ${createErrorMessage}. Rolling back...`)
        const rollbackContainer = this.docker.getContainer((await this.docker.listContainers({ all: true })).find((c) => c.Names.includes(`/${oldName}`))!.Id)
        await rollbackContainer.rename({ name: serviceName })
        await rollbackContainer.start()
        this.activeInstallations.delete(serviceName)
        return { success: false, message: `Failed to create updated container: ${createErrorMessage}` }
      }

      // Step 5: Start new container
      this._broadcast(serviceName, 'update-starting', `Starting updated container...`)
      await newContainer.start()

      // Step 6: Health check — verify container stays running for 5 seconds
      await new Promise((resolve) => setTimeout(resolve, 5000))
      const newContainerInfo = await newContainer.inspect()

      if (newContainerInfo.State?.Running) {
        // Healthy — clean up old container
        try {
          const oldContainerRef = this.docker.getContainer(
            (await this.docker.listContainers({ all: true })).find((c) =>
              c.Names.includes(`/${oldName}`)
            )?.Id || ''
          )
          await oldContainerRef.remove({ force: true })
        } catch {
          // Old container may already be gone
        }

        // Update DB
        service.container_image = newImage
        service.available_update_version = null
        await service.save()

        this.activeInstallations.delete(serviceName)
        this._broadcast(
          serviceName,
          'update-complete',
          `Successfully updated ${serviceName} to ${targetVersion}`
        )
        return { success: true, message: `Service ${serviceName} updated to ${targetVersion}` }
      } else {
        // Unhealthy — rollback
        this._broadcast(
          serviceName,
          'update-rollback',
          `New container failed health check. Rolling back to previous version...`
        )

        try {
          await newContainer.stop({ t: 5 }).catch(() => {})
          await newContainer.remove({ force: true })
        } catch {
          // Best effort cleanup
        }

        // Restore old container
        const oldContainers = await this.docker.listContainers({ all: true })
        const oldRef = oldContainers.find((c) => c.Names.includes(`/${oldName}`))
        if (oldRef) {
          const rollbackContainer = this.docker.getContainer(oldRef.Id)
          await rollbackContainer.rename({ name: serviceName })
          await rollbackContainer.start()
        }

        this.activeInstallations.delete(serviceName)
        return {
          success: false,
          message: `Update failed: new container did not stay running. Rolled back to previous version.`,
        }
      }
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      this.activeInstallations.delete(serviceName)
      this._broadcast(
        serviceName,
        'update-rollback',
        `Update failed: ${errorMessage}`
      )
      logger.error(`[DockerService] Update failed for ${serviceName}: ${errorMessage}`)
      return { success: false, message: `Update failed: ${errorMessage}` }
    }
  }

  private _broadcast(service: string, status: string, message: string) {
    void broadcastTransmit(BROADCAST_CHANNELS.SERVICE_INSTALLATION, {
      service_name: service,
      timestamp: new Date().toISOString(),
      status,
      message,
    })
    logger.info(`[DockerService] [${service}] ${status}: ${message}`)
  }

  async repairLegacyContainerIfNeeded(service: Service): Promise<void> {
    if (!service.installed || this.activeInstallations.has(service.service_name)) {
      return
    }

    try {
      const requiresRepair = await this._shouldRepairContainer(service)
      if (!requiresRepair) {
        return
      }

      logger.warn(
        `[DockerService] Detected stale container wiring for ${service.service_name}. Recreating it with the current runtime configuration.`
      )

      const result = await this.forceReinstall(service.service_name)
      if (!result.success) {
        logger.warn(`[DockerService] Failed to repair ${service.service_name}: ${result.message}`)
      }
    } catch (error) {
      logger.warn(
        `[DockerService] Failed to inspect ${service.service_name} for repair: ${getErrorMessage(error)}`
      )
    }
  }

  private _parseContainerConfig(containerConfig: any): any {
    if (!containerConfig) {
      return {}
    }

    try {
      // Handle the case where containerConfig is returned as an object by DB instead of a string
      let toParse = containerConfig
      if (typeof containerConfig === 'object') {
        toParse = JSON.stringify(containerConfig)
      }

      const parsed = JSON.parse(toParse)
      const binds = parsed?.HostConfig?.Binds

      if (Array.isArray(binds)) {
        parsed.HostConfig.Binds = binds.map((bind) => this._normalizeStorageBind(bind))
      }

      return parsed
    } catch (error) {
      const errorMessage = getErrorMessage(error)
      logger.error(`Failed to parse container configuration: ${errorMessage}`)
      throw new Error(`Invalid container configuration: ${errorMessage}`)
    }
  }

  private _normalizeStorageBind(bind: string): string {
    if (typeof bind !== 'string') {
      return bind
    }

    const [source, destination, ...rest] = bind.split(':')
    if (!source || !destination) {
      return bind
    }

    const storageMatch = source.match(/(?:^|[/\\])storage[/\\]([^:/\\]+)$/)
    if (!storageMatch) {
      return bind
    }

    const normalizedSource = resolve(this.getHostStorageRoot(), storageMatch[1])
    return [normalizedSource, destination, ...rest].join(':')
  }

  private async _shouldRepairContainer(service: Service): Promise<boolean> {
    const containers = await this.docker.listContainers({ all: true })
    const containerInfo = containers.find((container) =>
      container.Names.includes(`/${service.service_name}`)
    )

    if (!containerInfo) {
      return false
    }

    const inspection = await this.docker.getContainer(containerInfo.Id).inspect()

    if (service.service_name === SERVICE_NAMES.KIWIX) {
      const currentCmd = inspection.Config?.Cmd || []
      if (currentCmd.some((entry: string) => entry.includes('*.zim'))) {
        return true
      }
    }

    const desiredConfig = this._parseContainerConfig(service.container_config)
    const desiredBinds = desiredConfig?.HostConfig?.Binds

    if (!Array.isArray(desiredBinds) || desiredBinds.length === 0) {
      return false
    }

    const actualMounts = new Map<string, string>()
    for (const mount of inspection.Mounts || []) {
      if (mount.Type === 'bind' && mount.Destination && mount.Source) {
        actualMounts.set(mount.Destination, mount.Source)
      }
    }

    for (const bind of desiredBinds) {
      if (typeof bind !== 'string') {
        continue
      }

      const [desiredSource, destination] = bind.split(':')
      if (!desiredSource || !destination) {
        continue
      }

      const actualSource = actualMounts.get(destination)
      if (!actualSource) {
        return true
      }

      if (resolve(actualSource) !== resolve(desiredSource)) {
        return true
      }
    }

    return false
  }

  /**
   * Check if a Docker image exists locally.
   * @param imageName - The name and tag of the image (e.g., "nginx:latest")
   * @returns - True if the image exists locally, false otherwise
   */
  private async _checkImageExists(imageName: string): Promise<boolean> {
    try {
      const images = await this.docker.listImages()

      // Check if any image has a RepoTag that matches the requested image
      return images.some((image) => image.RepoTags && image.RepoTags.includes(imageName))
    } catch (error) {
      logger.warn(`Error checking if image exists: ${getErrorMessage(error)}`)
      // If run into an error, assume the image does not exist
      return false
    }
  }
}
