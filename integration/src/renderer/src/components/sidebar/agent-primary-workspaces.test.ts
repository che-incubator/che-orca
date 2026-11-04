import { describe, expect, it } from "vitest";
import { hideAgentPrimaryWorktrees } from "./agent-primary-workspaces";
import type { ExecutionHostId } from "../../../../shared/execution-host";

const environments = [
  { id: "agent", source: "ephemeral-vm" as const },
  { id: "controller", source: "manual" as const },
];
const checkout = (id: string, hostId: ExecutionHostId, isMainWorktree: boolean) => ({
  id,
  repoId: "repo",
  hostId,
  isMainWorktree,
});

describe("agent primary checkout visibility", () => {
  it("hides only the backing checkout of an agent with a named worktree", () => {
    const worktrees = [
      checkout("controller", "runtime:controller", true),
      checkout("backing", "runtime:agent", true),
      checkout("named", "runtime:agent", false),
    ];
    expect(
      hideAgentPrimaryWorktrees(worktrees, new Map(), environments, "local").map((w) => w.id),
    ).toEqual(["controller", "named"]);
    expect(worktrees).toHaveLength(3);
  });
  it("keeps the primary checkout until a named worktree exists in that environment", () => {
    const worktrees = [
      checkout("backing", "runtime:agent", true),
      checkout("elsewhere", "runtime:controller", false),
    ];
    expect(hideAgentPrimaryWorktrees(worktrees, new Map(), environments, "local")).toEqual(
      worktrees,
    );
  });
  it("keeps local and manually paired primary checkouts", () => {
    const worktrees = [
      checkout("local", "local", true),
      checkout("linked-local", "local", false),
      checkout("manual", "runtime:controller", true),
      checkout("linked-manual", "runtime:controller", false),
    ];
    expect(hideAgentPrimaryWorktrees(worktrees, new Map(), environments, "local")).toEqual(
      worktrees,
    );
  });
});
