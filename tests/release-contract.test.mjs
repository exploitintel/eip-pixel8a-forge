import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const root = path.resolve(new URL("..", import.meta.url).pathname);
const builder = path.join(root, "deployment", "build-simple-package.sh");

function packageArguments(t, extra = []) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "pixel8a-package-contract-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const forge = path.join(directory, "forge");
  fs.mkdirSync(forge);
  const files = {};
  for (const name of ["module", "kernel", "grant", "lock", "apk"]) {
    files[name] = path.join(directory, name);
    fs.writeFileSync(files[name], "not a qualified artifact\n");
  }
  return [builder,
    "--forge-source", forge,
    "--module", files.module,
    "--kernel", files.kernel,
    "--ksu-grant-helper", files.grant,
    "--image-lock", files.lock,
    "--apk", files.apk,
    "--output", path.join(directory, "output"),
    ...extra.map((value) => value.replace("$DIR", directory)),
  ];
}

test("package assembly rejects a kernel that is not the qualified Pixel 8a image", (t) => {
  const result = spawnSync("/bin/bash", packageArguments(t), { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /kernel image does not match the qualified Pixel 8a kernel/);
});

test("package assembly rejects a partial fresh-install payload", (t) => {
  const directoryToken = "$DIR";
  const args = packageArguments(t, [
    "--stock-boot", `${directoryToken}/module`,
    "--ksu-init-boot", `${directoryToken}/module`,
  ]);
  const result = spawnSync("/bin/bash", args, { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /--engine, --stock-boot, --ksu-init-boot, and --ksu-apk must be supplied together/);
});
