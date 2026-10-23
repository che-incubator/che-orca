import {
  getWorktreeExecutionHostId,
  toRuntimeExecutionHostId,
  type ExecutionHostId,
} from "../../../../shared/execution-host";
import type { Repo } from "../../../../shared/repo-types";
import type { PublicKnownRuntimeEnvironment } from "../../../../shared/runtime-environments";
import type { Worktree } from "../../../../shared/worktree/types";

// Keep the backing checkout in Git and the runtime catalog; only hide its sidebar
// card once the agent has a named worktree in the same environment.
export function hideAgentPrimaryWorktrees<
  T extends Pick<Worktree, "repoId" | "hostId" | "isMainWorktree">,
>(
  worktrees: readonly T[],
  repos: ReadonlyMap<string, Pick<Repo, "connectionId" | "executionHostId">>,
  environments: readonly Pick<PublicKnownRuntimeEnvironment, "id" | "source">[],
  defaultHostId: ExecutionHostId,
): T[] {
  const agentHosts = new Set<ExecutionHostId>(
    environments
      .filter((env) => env.source === "ephemeral-vm")
      .map((env) => toRuntimeExecutionHostId(env.id)),
  );
  const hostFor = (worktree: T) =>
    getWorktreeExecutionHostId(worktree, repos.get(worktree.repoId), defaultHostId);
  const hostsWithWorktrees = new Set(
    worktrees.filter((worktree) => !worktree.isMainWorktree).map(hostFor),
  );
  return worktrees.filter((worktree) => {
    const host = hostFor(worktree);
    return !worktree.isMainWorktree || !agentHosts.has(host) || !hostsWithWorktrees.has(host);
  });
}
