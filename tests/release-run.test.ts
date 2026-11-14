import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

// release-run.sh on a host without pnpm, against a stub `docker` that logs
// its arguments one per line, so no container runs. PATH holds only the
// tools the script needs, so a pnpm on the real PATH cannot take the
// host branch.
const root = resolve(import.meta.dirname, "..");
const tmp = mkdtempSync(join(tmpdir(), "release-run-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const which = (tool: string) => {
  const r = spawnSync("sh", ["-c", `command -v ${tool}`], { encoding: "utf8" });
  expect(r.status).toBe(0);
  return r.stdout.trim();
};
const bash = which("bash");

let n = 0;
function setup() {
  const dir = join(tmp, `w${n++}`);
  for (const d of ["scripts/develop.d", ".devcontainer", "bin"]) {
    mkdirSync(join(dir, d), { recursive: true });
  }
  for (const f of [
    "scripts/release-run.sh",
    "scripts/release-lib.sh",
    "scripts/develop.d/10-corepack.sh",
    ".devcontainer/Dockerfile",
  ]) {
    copyFileSync(join(root, f), join(dir, f));
  }
  for (const tool of ["sed", "dirname", "id"]) {
    symlinkSync(which(tool), join(dir, "bin", tool));
  }
  writeFileSync(
    join(dir, "bin", "docker"),
    `#!${bash}\nprintf '%s\\n' "$@" >"${dir}/docker.log"\n`,
  );
  chmodSync(join(dir, "bin", "docker"), 0o755);
  return dir;
}

// The names passed to `docker run` as `-e NAME` (forwarded from the
// caller's environment), not `-e NAME=value`.
function forwarded(script: string, env: Record<string, string>) {
  const dir = setup();
  const r = spawnSync(bash, [join(dir, "scripts/release-run.sh"), script], {
    cwd: dir,
    encoding: "utf8",
    env: { PATH: join(dir, "bin"), ...env },
  });
  expect(r.stderr).toBe("");
  expect(r.status).toBe(0);
  const args = readFileSync(join(dir, "docker.log"), "utf8").split("\n");
  return args.flatMap((a, i) =>
    args[i - 1] === "-e" && !a.includes("=") ? [a] : [],
  );
}

describe("release-run.sh (no pnpm on the host)", () => {
  it.each(["npm_config_dry_run", "NPM_CONFIG_DRY_RUN"])(
    "forwards %s to release-publish.sh, so the documented dry run stays one",
    (name) => {
      expect(
        forwarded("scripts/release-publish.sh", { [name]: "true" }),
      ).toContain(name);
    },
  );

  it("forwards neither NPM_TOKEN nor runner variables to the build", () => {
    const names = forwarded("scripts/release-build.sh", {
      NPM_TOKEN: "t",
      GITHUB_TOKEN: "t",
      GITHUB_REPOSITORY: "o/r",
    });
    expect(names).toContain("RELEASE_VERSION");
    expect(names).not.toContain("NPM_TOKEN");
    expect(names).not.toContain("GITHUB_REPOSITORY");
    expect(names).not.toContain("GITHUB_TOKEN");
  });

  it("forwards the job environment minus GITHUB_TOKEN to release-publish.sh", () => {
    const names = forwarded("scripts/release-publish.sh", {
      NPM_TOKEN: "t",
      GITHUB_TOKEN: "t",
      GITHUB_REPOSITORY: "o/r",
    });
    expect(names).toContain("NPM_TOKEN");
    expect(names).toContain("GITHUB_REPOSITORY");
    expect(names).not.toContain("GITHUB_TOKEN");
  });
});
