import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

// The Makefile half of template-base's release contract (>= 1.9.0): the npm
// upload belongs to `publish-packages`, which runs once in its own job, and
// the per-arch `publish` must not upload anything.
const root = resolve(import.meta.dirname, "..");

function dryRun(target: string) {
  return spawnSync("make", ["-n", target], { cwd: root, encoding: "utf8" });
}

describe("release Makefile contract", () => {
  it("publish-packages runs the npm upload script", () => {
    const r = dryRun("publish-packages");
    expect(r.status).toBe(0);
    expect(r.stdout).toContain(
      "scripts/release-run.sh scripts/release-publish.sh",
    );
  });

  it("publish (per arch) does not upload packages", () => {
    const r = dryRun("publish");
    expect(r.status).toBe(0);
    expect(r.stdout).not.toContain("release-publish.sh");
    expect(r.stdout).not.toMatch(/npm (stage )?publish/);
  });
});
