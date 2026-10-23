export type Configuration = { namespace: string; labels: Record<string, string>; runtimeClass: string; timeoutMs: number; template: string }
export type Resource = { namespace: string; name: string }
export type RecipeResult = { schemaVersion: 1; pairingCode: string; projectRoot: string; userData: Resource }
export function configuration(env?: NodeJS.ProcessEnv): Configuration | null
export class DevWorkspaceProvider {
  constructor(config: Configuration)
  allocation(id?: string): Resource
  create(resource: Resource, repoUrl: string, signal?: AbortSignal): Promise<RecipeResult>
  resume(resource: Resource, signal?: AbortSignal): Promise<RecipeResult>
  suspend(resource: Resource, signal?: AbortSignal): Promise<void>
  destroy(resource: Resource): Promise<void>
}
