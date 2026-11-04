import type { KnownRuntimeEnvironment } from '../../../../shared/runtime-environments'

// Pairing credentials stay in memory; the controlling server persists them securely.
// They are reloaded after reconnecting instead of being copied into browser storage.
export const cheEnvironments = new Map<string, KnownRuntimeEnvironment>()

export function setCheEnvironments(environments: KnownRuntimeEnvironment[]): void {
  cheEnvironments.clear()
  for (const environment of environments) cheEnvironments.set(environment.id, environment)
}
