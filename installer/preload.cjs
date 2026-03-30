const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('roachnetSetup', {
  getState: () => ipcRenderer.invoke('setup:get-state'),
  saveConfig: (updates) => ipcRenderer.invoke('setup:save-config', updates),
  startContainerRuntime: () => ipcRenderer.invoke('setup:start-container-runtime'),
  runInstall: (payload) => ipcRenderer.invoke('setup:run-install', payload),
  launchMainApp: () => ipcRenderer.invoke('setup:launch-main-app'),
  openDockerDocs: () => ipcRenderer.invoke('setup:open-docker-docs'),
  openInstallFolder: () => ipcRenderer.invoke('setup:open-install-folder'),
  openMainDownloads: () => ipcRenderer.invoke('setup:open-main-downloads'),
})
