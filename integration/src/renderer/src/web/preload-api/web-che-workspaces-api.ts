import type { PreloadApi } from '../../../../preload/api-types'
import type { KnownRuntimeEnvironment } from '../../../../shared/runtime-environments'
import { callRuntimeResult } from './web-runtime-calls'
import { setCheEnvironments } from './web-che-environments'
import { assertActiveEnvironment, requireActiveEnvironment, getClientForEnvironment, closeCheRuntimeClients, invalidateRuntimeWorktreeCaches } from './web-runtime-session'
import { noopUnsubscribe } from './web-storage'

export async function refreshCheEnvironments(): Promise<KnownRuntimeEnvironment[]> {
  const controller = requireActiveEnvironment().id
  const environments = await callRuntimeResult<KnownRuntimeEnvironment[]>('cheWorkspace.environments')
  assertActiveEnvironment(controller)
  if (!Array.isArray(environments)) throw new Error('Invalid Che runtime environment response.')
  setCheEnvironments(environments)
  return environments
}

export function createWebCheWorkspacesApi(): PreloadApi['ephemeralVm'] {
  const call = <T>(method: string, args?: unknown) => callRuntimeResult<T>(`cheWorkspace.${method}`, args, 360_000)
  return {
    listRecipes: (args) => call('listRecipes', args),
    listRecipeCatalog: async () => [],
    doctor: async () => { throw new Error('Che environment configuration is managed by the deployment administrator.') },
    provision: async (args) => {
      const result = await call<Awaited<ReturnType<PreloadApi['ephemeralVm']['provision']>>>('provision', args)
      if (result.ok) await refreshCheEnvironments()
      return result
    },
    // Cancellation must not queue behind a full set of long-running creates.
    cancelProvision: async (args) => {
      const environment = requireActiveEnvironment()
      const response = await getClientForEnvironment(environment).call('cheWorkspace.cancelProvision', args, { timeoutMs: 15_000 })
      if (!response.ok) throw new Error(response.error.message)
      return response.result as { cancelled: boolean }
    },
    onProvisionEvent: () => noopUnsubscribe,
    listRuntimes: () => call('listRuntimes'),
    attachWorkspace: (args) => call('attachWorkspace', args),
    suspendWorkspace: async (args) => {
      const row = await call<Awaited<ReturnType<PreloadApi['ephemeralVm']['suspendWorkspace']>>>('suspendWorkspace', args)
      if (row?.runtimeEnvironmentId) closeCheRuntimeClients(row.runtimeEnvironmentId)
      return row
    },
    resumeWorkspace: async (args) => {
      const row = await call<Awaited<ReturnType<PreloadApi['ephemeralVm']['resumeWorkspace']>>>('resumeWorkspace', args)
      if (row?.runtimeEnvironmentId) closeCheRuntimeClients(row.runtimeEnvironmentId)
      await refreshCheEnvironments()
      return row
    },
    cleanup: async (args) => {
      const row = await call<Awaited<ReturnType<PreloadApi['ephemeralVm']['cleanup']>>>('cleanup', args)
      if (row.runtimeEnvironmentId) closeCheRuntimeClients(row.runtimeEnvironmentId)
      await refreshCheEnvironments()
      invalidateRuntimeWorktreeCaches()
      return row
    },
    stopCleanup: async () => { throw new Error('Wait for the Kubernetes cleanup operation to finish, then retry if needed.') },
    getCleanupCommand: async ({ runtimeId }) => ({ runtimeId, command: null,
      payloadJson: '{}', cleanupDisabled: false, message: 'This environment is managed through the Che DevWorkspace API.' })
  }
}
