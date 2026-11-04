import { randomUUID } from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { z } from 'zod'
import { getAppEnvironment } from '../../shared/app-environment'
import { listEphemeralVmRuntimes, upsertEphemeralVmRuntime, updateEphemeralVmRuntimeStatus } from '../../shared/ephemeral-vm-runtime-store'
import { addEnvironmentFromPairingCode, listEnvironments, removeEnvironment, updateEnvironmentFromPairingCode } from '../../shared/runtime-environment-store'
import { redactRuntimeEnvironment } from '../../shared/runtime-environments'
import { defineMethod, InvalidArgumentError } from '../runtime/rpc/core'
import { checkRepoUrl, configuration, DevWorkspaceProvider, type Resource } from './devworkspace-provider.mjs'
import type { EphemeralVmRuntimeRecord } from '../../shared/ephemeral-vm-runtimes'

const recipe = { id: 'che-devworkspace', name: 'Che DevWorkspace', create: 'che:managed',
  suspend: 'che:managed', resume: 'che:managed', destroy: 'che:managed' }
const controllers = new Map<string, AbortController>()
const operations = new Set<string>()
const dataPath = () => getAppEnvironment().getPath('userData')
const records = () => listEphemeralVmRuntimes(dataPath()).filter((row) => row.recipeId === recipe.id)
const provider = () => {
  const config = configuration()
  if (!config) throw new InvalidArgumentError('DevWorkspace provisioning is not configured on this Orca server.')
  return new DevWorkspaceProvider(config)
}

// Agent workspaces are an upgrade, not a requirement: when this server cannot create
// one, the composer offers only its normal targets and workspaces stay on this host.
type Probe = { repoUrl: string } | { reason: string | null }
type Repo = { path: string; kind?: string }
const run = promisify(execFile)
const CLUSTER_CHECK_MS = 30_000
let clusterCheck: { at: number; reason: Promise<string | null> } | null = null
let loggedReason: string | null = null

function clusterUnavailable(backend: DevWorkspaceProvider): Promise<string | null> {
  if (!clusterCheck || Date.now() - clusterCheck.at > CLUSTER_CHECK_MS) {
    const reason = backend.unavailable(AbortSignal.timeout(10_000)).catch((error) => String(error))
    clusterCheck = { at: Date.now(), reason }
  }
  return clusterCheck.reason
}

// A null reason means the feature is not configured, which needs no explanation.
async function probe(repo: Repo | undefined): Promise<Probe> {
  let config
  try { config = configuration() } catch (error) { return { reason: error instanceof Error ? error.message : String(error) } }
  if (!config) return { reason: null }
  if (!repo || repo.kind === 'folder') return { reason: 'The project is not a Git repository.' }
  let repoUrl: string
  try {
    repoUrl = (await run('git', ['remote', 'get-url', 'origin'], { cwd: repo.path, encoding: 'utf8', timeout: 10_000 })).stdout.trim()
    checkRepoUrl(repoUrl)
  } catch (error) {
    return { reason: error instanceof Error && !('code' in error) ? error.message : 'The project has no Git origin.' }
  }
  const reason = await clusterUnavailable(new DevWorkspaceProvider(config))
  return reason ? { reason } : { repoUrl }
}

function logUnavailable(reason: string | null) {
  if (!reason || reason === loggedReason) return
  loggedReason = reason
  console.warn(`Agent workspaces unavailable; creating workspaces on this host: ${reason}`)
}

const find = (id: string) => {
  const row = records().find((entry) => entry.id === id)
  if (!row) throw new InvalidArgumentError('Unknown Che DevWorkspace runtime.')
  return row
}
const resource = (row: EphemeralVmRuntimeRecord) => row.recipeResult.userData as Resource
const update = (id: string, patch: Parameters<typeof updateEphemeralVmRuntimeStatus>[2]) => updateEphemeralVmRuntimeStatus(dataPath(), id, patch)
const exclusive = async <T>(id: string, operation: () => Promise<T>): Promise<T> => {
  if (operations.has(id)) throw new InvalidArgumentError('An environment lifecycle operation is already running.')
  operations.add(id)
  try { return await operation() } finally { operations.delete(id) }
}

async function cleanup(row: EphemeralVmRuntimeRecord) {
  if (row.status === 'cleaned') return row
  update(row.id, { status: 'cleanup_pending', cleanupStatus: 'running' })
  try {
    await provider().destroy(resource(row))
    if (row.runtimeEnvironmentId && listEnvironments(dataPath()).some((env) => env.id === row.runtimeEnvironmentId)) {
      removeEnvironment(dataPath(), row.runtimeEnvironmentId)
    }
    return update(row.id, { status: 'cleaned', cleanupStatus: 'succeeded', cleanupLastError: null })
  } catch (error) {
    return update(row.id, { status: 'cleanup_failed', cleanupStatus: 'failed', cleanupLastError: String(error) })
  }
}

const RuntimeId = z.object({ runtimeId: z.string().min(1) })
const WorkspaceId = z.object({ workspaceId: z.string().min(1) })

export const CHE_WORKSPACE_METHODS = [
  defineMethod({ name: 'cheWorkspace.listRecipes', params: z.object({ repoId: z.string() }),
    handler: async ({ repoId }, { runtime }) => {
      const repo = runtime.listRepos().find((entry) => entry.id === repoId)
      const result = await probe(repo)
      if ('reason' in result) logUnavailable(result.reason)
      return { status: 'ok' as const, repoPath: repo?.path ?? null,
        recipes: 'repoUrl' in result ? [recipe] : [], diagnostics: [] }
    } }),
  // These credentials travel only through Orca's authenticated, encrypted runtime connection.
  defineMethod({ name: 'cheWorkspace.environments', params: null, handler: () => {
    const ids = new Set(records().filter((row) => row.status !== 'cleaned').map((row) => row.runtimeEnvironmentId))
    return listEnvironments(dataPath()).filter((env) => ids.has(env.id))
  } }),
  defineMethod({ name: 'cheWorkspace.listRuntimes', params: null,
    handler: () => records().filter((row) => row.status !== 'cleaned') }),
  defineMethod({ name: 'cheWorkspace.provision', params: z.object({
    repoId: z.string(), recipeId: z.literal('che-devworkspace'), projectId: z.string().optional(),
    workspaceId: z.string().optional(), workspaceName: z.string().optional(), provisionId: z.string().optional(),
    branch: z.string().optional(), ref: z.string().optional()
  }), handler: async (args, { runtime, signal }) => {
    const repo = runtime.listRepos().find((entry) => entry.id === args.repoId)
    const checked = await probe(repo)
    if (!('repoUrl' in checked)) {
      // Recheck at create time: the composer's recipe list can be stale.
      const error = checked.reason ?? 'Agent workspaces are not configured on this Orca server.'
      logUnavailable(error)
      return { ok: false as const, fallback: true, error, stdout: '', stderr: '' }
    }
    const { repoUrl } = checked
    const backend = provider()
    const id = randomUUID()
    const allocation = backend.allocation(id)
    const controller = new AbortController()
    const key = args.provisionId ?? id
    if (controllers.has(key)) throw new InvalidArgumentError('Provisioning is already running for this request.')
    const now = Date.now()
    upsertEphemeralVmRuntime(dataPath(), {
      id, recipeId: recipe.id, recipe, repoId: args.repoId, projectId: args.projectId,
      workspaceId: args.workspaceId, workspaceName: args.workspaceName,
      status: 'provisioning', cleanupStatus: 'not_started', createdAt: now, updatedAt: now,
      recipeResult: { schemaVersion: 1, pairingCode: 'pending', projectRoot: '/projects/source', userData: allocation }
    })
    controllers.set(key, controller)
    operations.add(id)
    const abort = () => controller.abort()
    signal?.addEventListener('abort', abort, { once: true })
    if (signal?.aborted) abort()
    try {
      const recipeResult = await backend.create(allocation, repoUrl, controller.signal)
      const environment = addEnvironmentFromPairingCode(dataPath(), {
        name: `${args.workspaceName || 'Che workspace'} (${id.slice(0, 8)})`,
        pairingCode: recipeResult.pairingCode, source: 'ephemeral-vm'
      })
      const row = update(id, { status: 'running', connectionMode: 'orca-server', runtimeEnvironmentId: environment.id, recipeResult })
      return { ok: true as const, connectionType: 'orca-server' as const, runtime: row,
        environment: redactRuntimeEnvironment(environment), stderr: '', warnings: [] }
    } catch (error) {
      // Rollback is not cancellable; a failed rollback stays recorded for retry.
      await cleanup(find(id))
      // Failures before the DevWorkspace exists (quota, admission, Route) fall back to this host.
      const fallback = error instanceof Error && (error as Error & { fallback?: boolean }).fallback === true
      if (fallback) clusterCheck = null
      return { ok: false as const, ...(fallback ? { fallback: true } : {}),
        error: error instanceof Error ? error.message : String(error), stdout: '', stderr: '' }
    } finally { signal?.removeEventListener('abort', abort); controllers.delete(key); operations.delete(id) }
  } }),
  defineMethod({ name: 'cheWorkspace.cancelProvision', params: z.object({ provisionId: z.string() }), handler: ({ provisionId }) => {
    const controller = controllers.get(provisionId)
    controller?.abort()
    return { cancelled: Boolean(controller) }
  } }),
  defineMethod({ name: 'cheWorkspace.attachWorkspace', params: RuntimeId.extend({ workspaceId: z.string() }),
    handler: ({ runtimeId, workspaceId }) => { find(runtimeId); return update(runtimeId, { workspaceId }) } }),
  defineMethod({ name: 'cheWorkspace.cleanup', params: RuntimeId,
    handler: ({ runtimeId }) => exclusive(runtimeId, () => cleanup(find(runtimeId))) }),
  defineMethod({ name: 'cheWorkspace.suspendWorkspace', params: WorkspaceId, handler: async ({ workspaceId }, { signal }) => {
    const row = records().find((entry) => entry.workspaceId === workspaceId && entry.status !== 'cleaned')
    if (!row || row.status === 'suspended') return row ?? null
    return exclusive(row.id, async () => {
      try { await provider().suspend(resource(row), signal); return update(row.id, { status: 'suspended' }) }
      catch (error) { update(row.id, { status: 'suspend_failed' }); throw error }
    })
  } }),
  defineMethod({ name: 'cheWorkspace.resumeWorkspace', params: WorkspaceId, handler: async ({ workspaceId }, { signal }) => {
    const row = records().find((entry) => entry.workspaceId === workspaceId && entry.status !== 'cleaned')
    if (!row || !['suspended', 'resume_failed', 'suspend_failed'].includes(row.status)) return row ?? null
    return exclusive(row.id, async () => {
      try {
        const recipeResult = await provider().resume(resource(row), signal)
        if (row.runtimeEnvironmentId) updateEnvironmentFromPairingCode(dataPath(), row.runtimeEnvironmentId, { pairingCode: recipeResult.pairingCode })
        return update(row.id, { status: 'running', recipeResult })
      } catch (error) { update(row.id, { status: 'resume_failed' }); throw error }
    })
  } })
]
