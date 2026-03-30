const { contextBridge, ipcRenderer } = require('electron')

function subscribe(channel, callback) {
  const handler = (_event, payload) => {
    callback(payload)
  }

  ipcRenderer.on(channel, handler)
  return () => {
    ipcRenderer.removeListener(channel, handler)
  }
}

contextBridge.exposeInMainWorld('roachnetDesktop', {
  nativeShell: true,
  getState: () => ipcRenderer.invoke('roachnet:get-state'),
  getAIState: () => ipcRenderer.invoke('roachnet:get-ai-state'),
  getAccelerationState: () => ipcRenderer.invoke('roachnet:get-acceleration-state'),
  getKnowledgeState: () => ipcRenderer.invoke('roachnet:get-knowledge-state'),
  saveConfig: (updates) => ipcRenderer.invoke('roachnet:save-config', updates),
  startMode: (mode) => ipcRenderer.invoke('roachnet:start-mode', mode),
  stopRuntime: () => ipcRenderer.invoke('roachnet:stop-runtime'),
  startContainerRuntime: () => ipcRenderer.invoke('roachnet:start-container-runtime'),
  runInstall: (payload) => ipcRenderer.invoke('roachnet:run-install', payload),
  checkForUpdates: () => ipcRenderer.invoke('roachnet:check-for-updates'),
  openInstallerHelper: () => ipcRenderer.invoke('roachnet:open-installer-helper'),
  searchModels: (options) => ipcRenderer.invoke('roachnet:search-models', options),
  downloadModel: (model) => ipcRenderer.invoke('roachnet:download-model', model),
  deleteModel: (model) => ipcRenderer.invoke('roachnet:delete-model', model),
  applyRoachClaw: (payload) => ipcRenderer.invoke('roachnet:apply-roachclaw', payload),
  searchSkills: (options) => ipcRenderer.invoke('roachnet:search-skills', options),
  installSkill: (payload) => ipcRenderer.invoke('roachnet:install-skill', payload),
  getChatSession: (sessionId) => ipcRenderer.invoke('roachnet:get-chat-session', sessionId),
  deleteChatSession: (sessionId) => ipcRenderer.invoke('roachnet:delete-chat-session', sessionId),
  sendChatMessage: (payload) => ipcRenderer.invoke('roachnet:send-chat-message', payload),
  scanKnowledgeStorage: () => ipcRenderer.invoke('roachnet:scan-knowledge-storage'),
  deleteKnowledgeFile: (source) => ipcRenderer.invoke('roachnet:delete-knowledge-file', source),
  selectAndUploadKnowledgeFiles: () => ipcRenderer.invoke('roachnet:select-and-upload-knowledge-files'),
  openInstallFolder: () => ipcRenderer.invoke('roachnet:open-install-folder'),
  openReleaseDownloads: () => ipcRenderer.invoke('roachnet:open-release-downloads'),
  openMlxDocs: () => ipcRenderer.invoke('roachnet:open-mlx-docs'),
  openExoDocs: () => ipcRenderer.invoke('roachnet:open-exo-docs'),
  onStateChange: (callback) => subscribe('roachnet:state', callback),
})
