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

  it("keeps the dry run away from the container's Corepack install", () => {
    const dir = setup();
    const r = spawnSync(
      bash,
      [join(dir, "scripts/release-run.sh"), "scripts/release-publish.sh"],
      { cwd: dir, encoding: "utf8", env: { PATH: join(dir, "bin") } },
    );
    expect(r.status).toBe(0);
    const install = readFileSync(join(dir, "docker.log"), "utf8")
      .split("\n")
      .find((l) => l.includes("npm install"));
    expect(install).toContain("-u npm_config_dry_run -u NPM_CONFIG_DRY_RUN");
  });

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

// use_npm in release-lib.sh with a stub npm on PATH that reports another
// version, so the pinned one is installed. The stub behaves like npm under
// a dry run: `install` then installs nothing.
describe("release-lib.sh use_npm", () => {
  const NPM_VERSION = /^NPM_VERSION=(.+)$/m.exec(
    readFileSync(join(root, "scripts/release-lib.sh"), "utf8"),
  )![1]!;

  it.each(["npm_config_dry_run", "NPM_CONFIG_DRY_RUN"])(
    "still installs the pinned npm under %s=true",
    (name) => {
      const dir = setup();
      writeFileSync(
        join(dir, "bin", "npm"),
        `#!${bash}
case "$1" in
  --version) echo 0.0.1 ;;
  install) # install --prefix <dir> ... npm@<version>
    if [ -n "\${npm_config_dry_run:-}\${NPM_CONFIG_DRY_RUN:-}" ]; then exit 0; fi
    mkdir -p "$3/node_modules/.bin"
    printf '#!${bash}\\necho ${NPM_VERSION}\\n' >"$3/node_modules/.bin/npm"
    chmod +x "$3/node_modules/.bin/npm" ;;
esac
`,
      );
      chmodSync(join(dir, "bin", "npm"), 0o755);
      for (const tool of ["env", "mktemp", "mkdir", "chmod", "rm"]) {
        symlinkSync(which(tool), join(dir, "bin", tool));
      }
      const r = spawnSync(
        bash,
        ["-c", "source scripts/release-lib.sh && use_npm && npm --version"],
        {
          cwd: dir,
          encoding: "utf8",
          env: { PATH: join(dir, "bin"), [name]: "true" },
        },
      );
      expect(r.stderr).toBe("");
      expect(r.status).toBe(0);
      expect(r.stdout.trim()).toBe(NPM_VERSION);
    },
  );
});
