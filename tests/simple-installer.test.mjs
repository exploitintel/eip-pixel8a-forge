import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import test from "node:test";

const installer = new URL("../deployment/simple-install.sh", import.meta.url);
const firmwarePreparer = new URL("../deployment/prepare-firmware.sh", import.meta.url);
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;

// Serialized into the fixture. Device commands are data and are never evaluated.
async function fakeToolMain() {
  const fs = await import("node:fs");
  const { spawnSync } = await import("node:child_process");
  const [tool, ...args] = process.argv.slice(2);
  const env = process.env;
  const log = (entry) => fs.appendFileSync(env.FAKE_CALLS, `${JSON.stringify(entry)}\n`);
  const reject = () => {
    process.stderr.write(`Unexpected fake ${tool} call: ${JSON.stringify(args)}\n`);
    process.exit(97);
  };
  if (tool === "sleep") {
    log({ tool, args });
    const delay = args[0] === "15" ? (env.FAKE_FAST_HEARTBEAT === "1" ? 35 : 1000) : 0;
    await new Promise((resolve) => setTimeout(resolve, delay));
    return;
  }
  if (tool === "shasum") {
    const file = args.at(-1);
    const hashes = new Map([
      ["stock-boot.img", "1a425630486ddc7150ac0669d1453cb20169c3df6d7db444929eedf8645db9eb"],
      ["ksu-init-boot.img", "9302c9957c191b6761ee06aacbd336641d2adae266d476b9272554bfb0a0a49e"],
      ["ksu-manager.apk", "fd0b12385c98fe9d5f4f1257b5f184e55c74c1376637507df0718305f5d7a924"],
      ["forge-source.tar", "f".repeat(64)],
      ["source-ops.txt", "9".repeat(64)],
    ]);
    const name = [...hashes.keys()].find((candidate) => file?.endsWith(`/${candidate}`));
    if (!name || args.slice(0, -1).join(" ") !== "-a 256 --") reject();
    const hash = env.FAKE_BAD_PAYLOAD === name ? "0".repeat(64) : hashes.get(name);
    log({ tool, file, hash });
    process.stdout.write(`${hash}  ${file}\n`);
    return;
  }
  if (tool === "unzip") {
    if (args.length === 3 && args[0] === "-p"
        && args[1].endsWith("/payload/host-module.zip") && args[2] === "module.prop") {
      log({ tool, args });
      process.stdout.write("id=eip-pixel8a-forge\nversion=0.1.0-rc.5\n");
      return;
    }
    if (args.length !== 3 || args[0] !== "-p"
        || !args[1].endsWith("/payload/ksu-manager.apk")
        || !args[2].startsWith("lib/arm64-v8a/")) reject();
    log({ tool, args });
    process.stdout.write("inert fixture member\n");
    return;
  }
  if (tool === "fastboot") {
    log({ tool, args });
    if (args.length === 1 && args[0] === "devices") {
      process.stdout.write("TEST-SERIAL\tfastboot\n");
      return;
    }
    const command = args.slice(2).join(" ");
    if (args[0] === "-s" && args[1] === "TEST-SERIAL" && command === "getvar product") {
      process.stderr.write(`product: ${env.FAKE_FASTBOOT_PRODUCT}\n`);
      return;
    }
    if (args[0] === "-s" && args[1] === "TEST-SERIAL"
        && (command === "-w" || command === "reboot")) return;
    reject();
  }
  if (tool !== "adb" || args[0] !== "-s" || args[1] !== "TEST-SERIAL") reject();
  const [, , verb, ...rest] = args;
  let command = rest.join(" ");
  if (verb === "shell" && rest[0] === "-T") {
    const wrapped = rest[1];
    if (rest.length !== 2 || !wrapped.startsWith("su -c '") || !wrapped.endsWith("'")) reject();
    command = wrapped.slice(7, -1).replaceAll("'\\''", "'");
  }
  log({ tool, verb, command });
  if (env.FAKE_FAIL_MATCH && command.includes(env.FAKE_FAIL_MATCH)) {
    process.stderr.write("Injected fixture command failure\n");
    process.exit(Number(env.FAKE_FAIL_STATUS));
  }
  if (env.FAKE_DELAY_MATCH && command.includes(env.FAKE_DELAY_MATCH)) {
    log({ event: "delay-started" });
    if (env.FAKE_DELAY_RELEASE) {
      fs.writeFileSync(env.FAKE_DELAY_READY, "waiting\n");
      const deadline = Date.now() + 5000;
      while (!fs.existsSync(env.FAKE_DELAY_RELEASE)) {
        if (Date.now() >= deadline) process.exit(95);
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      log({ event: "delay-released" });
    } else {
      await new Promise((resolve) => setTimeout(resolve, Number(env.FAKE_DELAY_MILLIS)));
    }
  }
  if (verb === "push" && rest.length === 2) {
    if (!fs.existsSync(rest[0]) || !rest[1].startsWith("/data/local/tmp/")) reject();
    if (rest[1] === "/data/local/tmp/eip-provider.env") {
      fs.copyFileSync(rest[0], env.FAKE_REMOTE_PROVIDER);
    }
    return;
  }
  if (verb === "pull" && rest.length === 2
      && rest[0] === "/data/local/tmp/eip-ksu-shell-root.img") {
    fs.writeFileSync(rest[1], Buffer.alloc(Number(env.FAKE_SHELL_ROOT_SIZE)));
    return;
  }
  if (verb === "reboot" && rest.length === 1 && rest[0] === "bootloader") return;
  if (verb === "reboot" && rest.length === 0) return;
  if (verb === "wait-for-device" && rest.length === 0) return;
  if (verb === "install" && rest.length === 2 && rest[0] === "-r"
      && rest[1].endsWith("/payload/forge-control.apk")) return;
  if (verb !== "shell") reject();
  const properties = new Map([
    ["getprop ro.product.device", env.FAKE_DEVICE],
    ["getprop ro.build.fingerprint", env.FAKE_FINGERPRINT],
    ["getprop ro.build.version.release", env.FAKE_ANDROID_VERSION],
    ["getprop ro.build.version.security_patch", env.FAKE_SECURITY_PATCH],
    ["getprop ro.boot.slot_suffix", "_a"],
    ["getprop sys.boot_completed", "1"],
  ]);
  if (properties.has(command)) {
    process.stdout.write(`${properties.get(command)}\n`);
    return;
  }
  if (command === "su -c 'id -u'") {
    if (env.FAKE_ROOT_AVAILABLE === "0") process.exit(1);
    process.stdout.write("0\n");
    return;
  }
  if (command === "pm list packages -U com.exploitintel.forgecontrol") {
    process.stdout.write("package:com.exploitintel.forgecontrol uid:10123\n");
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh start") {
    fs.writeFileSync(env.FAKE_STARTED, "started\n");
    return;
  }
  if (command === "/data/docker/bin/hostctl start") {
    fs.writeFileSync(env.FAKE_DOCKER_RUNNING, "running\n");
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh park") {
    fs.rmSync(env.FAKE_DOCKER_RUNNING, { force: true });
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh park-when-idle") {
    fs.writeFileSync(env.FAKE_PARK_PENDING, "pending\n");
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh reconcile") {
    if (fs.existsSync(env.FAKE_PARK_PENDING)) {
      fs.writeFileSync(env.FAKE_PARKED, "parked\n");
      fs.rmSync(env.FAKE_DOCKER_RUNNING, { force: true });
    }
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh cancel-park-when-idle") {
    fs.rmSync(env.FAKE_PARK_PENDING, { force: true });
    return;
  }
  if (command === "/data/docker/bin/hostctl disk-init --size-bytes 68719476736"
      || command === "/data/docker/bin/hostctl disk-init") {
    return;
  }
  if (command === "if test -x /data/adb/modules_update/eip-pixel8a-forge/bin/kernelctl; then printf /data/adb/modules_update/eip-pixel8a-forge; else printf /data/adb/modules/eip-pixel8a-forge; fi") {
    process.stdout.write("/data/adb/modules_update/eip-pixel8a-forge");
    return;
  }
  if (command === "/data/eip-cve-ops/eip.sh up --force-recreate --no-deps ui") {
    if (!fs.existsSync(env.FAKE_DOCKER_RUNNING)) process.exit(94);
    fs.writeFileSync(env.FAKE_UI_STARTED, "started\n");
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh status") {
    let status = "schema_version=1\nsystem=ready\ndocker=running\nforge=running\n"
      + "ui_health=healthy\nchat_health=healthy\nwork=idle\nactive_count=0\n"
      + "unknown_containers=0\ndrain=off\nboot_policy=unmanaged\n"
      + "active_kind=none\nactive_cve=none\nactive_phase=none\nactive_started_at=none\n";
    if (fs.existsSync(env.FAKE_PARKED) && !fs.existsSync(env.FAKE_STARTED)) {
      status = status.replace("system=ready", "system=parked")
        .replace("forge=running", "forge=stopped")
        .replace("ui_health=healthy", "ui_health=absent")
        .replace("chat_health=healthy", "chat_health=absent");
    }
    const started = fs.existsSync(env.FAKE_STARTED);
    const uiStarted = fs.existsSync(env.FAKE_UI_STARTED);
    if (uiStarted && !started && env.FAKE_UI_STATUS_MODE === "never-ready") {
      status = status.replace("system=ready", "system=degraded")
        .replace("forge=running", "forge=partial").replace("ui_health=healthy", "ui_health=starting");
    }
    if (started && env.FAKE_STATUS_MODE === "never-ready") {
      status = status.replace("system=ready", "system=degraded")
        .replace("forge=running", "forge=partial").replace("ui_health=healthy", "ui_health=starting");
    }
    process.stdout.write(status);
    if (started && env.FAKE_STATUS_MODE === "failed") process.exit(37);
    return;
  }
  if (command === "test -f /data/eip-cve/container.env"
      && env.FAKE_FORGE_STATE_EXISTS === "0") {
    process.exit(1);
  }
  if (command === "test -x /data/docker/bin/docker && test -f /data/docker/disk.img && test -f /data/docker/config/host.conf && test -f /data/eip-cve/container.env && test -x /data/eip-cve-ops/eip-hostctl.sh && pm path com.exploitintel.forgecontrol >/dev/null") {
    process.exit(env.FAKE_EXISTING_INSTALL === "1" ? 0 : 1);
  }
  if (command.startsWith("test \"$(sed -n 's/^id=//p' /data/adb/modules/eip-pixel8a-forge/module.prop")) {
    process.exit(env.FAKE_HOST_MODULE_CURRENT === "1" ? 0 : 1);
  }
  const docker = "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker";
  const controllerRef = `ghcr.io/exploitintel/eip-pixel8a-forge-controller@sha256:${"a".repeat(64)}`;
  const operatorRef = `ghcr.io/exploitintel/eip-pixel8a-forge-operator@sha256:${"b".repeat(64)}`;
  if (command === `${docker} pull ${controllerRef}` || command === `${docker} pull ${operatorRef}`) return;
  if (command === `${docker} image inspect --format '{{.Id}}' ${controllerRef}`) {
    process.stdout.write(`${env.FAKE_LOADED_CONTROLLER_ID}\n`);
    return;
  }
  if (command === `${docker} image inspect --format '{{.Id}}' ${operatorRef}`) {
    process.stdout.write(`${env.FAKE_LOADED_OPERATOR_ID}\n`);
    return;
  }
  if (command === `${docker} tag ${controllerRef} eip-cve-controller:local`
      || command === `${docker} tag ${controllerRef} eip-cve-controller:phone`
      || command === `${docker} tag ${operatorRef} eip-operator-shell:phone`
      || command === `${docker} tag ${operatorRef} eip-operator-shell:candidate`) return;
  if (command === `${docker} info >/dev/null 2>&1`) {
    if (!fs.existsSync(env.FAKE_DOCKER_RUNNING)) process.exit(1);
    return;
  }
  if (command === "/data/eip-cve-ops/eip-hostctl.sh logs") {
    process.stdout.write("fixture readiness log\n");
    return;
  }
  if (command === "/data/eip-cve-ops/eip.sh password") {
    process.stdout.write("EIP_CVE_UI_USER=operator\nEIP_CVE_UI_PASSWORD=fixture-webui-password\n");
    return;
  }
  if (command.startsWith("/data/eip-cve-ops/merge-env.sh ")) {
    // This is the only extracted remote command executed locally. Its entire
    // grammar is checked before both phone paths are remapped into this fixture.
    const allowed = /^\/data\/eip-cve-ops\/merge-env\.sh < \/data\/local\/tmp\/eip-provider\.env; (?:rc=\$\?; )?rm -f \/data\/local\/tmp\/eip-provider\.env(?:; exit \$rc)?$/;
    if (!allowed.test(command)) reject();
    const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
    const safe = command.replaceAll("/data/eip-cve-ops/merge-env.sh", quote(env.FAKE_MERGE_HELPER))
      .replaceAll("/data/local/tmp/eip-provider.env", quote(env.FAKE_REMOTE_PROVIDER));
    const result = spawnSync("/bin/bash", ["-c", safe], { env, encoding: "utf8" });
    log({ event: "merge-finished", status: result.status,
      cleaned: !fs.existsSync(env.FAKE_REMOTE_PROVIDER) });
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 96);
  }
  const exact = new Set([
    "true", "test -x /data/docker/bin/docker", "test -x /data/eip-cve-ops/eip-hostctl.sh",
    "test -f /data/eip-cve/container.env", "/data/eip-cve-ops/eip-hostctl.sh park",
    "/data/eip-cve-ops/eip.sh bootstrap",
    "/data/eip-cve-ops/eip.sh up --force-recreate --no-deps ui",
    "/data/eip-cve-ops/eip.sh skills-release",
    "/data/eip-cve-ops/eip.sh logs --no-color --tail 40 ui",
    "/data/eip-cve-ops/eip.sh down",
    "/data/eip-cve-ops/set-ollama.sh https://ollama.com",
    "am start -n com.exploitintel.forgecontrol/.MainActivity >/dev/null",
    "pm grant com.exploitintel.forgecontrol android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true",
    "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker info >/dev/null 2>&1",
    "/data/docker/bin/hostctl start", "/data/docker/bin/hostctl disk-init --size-bytes 68719476736",
    "/data/adb/ksud module install /data/local/tmp/eip-pixel8a-forge.zip",
    "KSU=true KSU_VER=3.3.0 KSU_VER_CODE=33214 KSU_RUNTIME_MODE=lkm /data/adb/modules_update/eip-pixel8a-forge/bin/kernelctl install INSTALL:CP2A.260805.005:_a",
    "rm -f /data/local/tmp/docker-29.8.0.tgz /data/local/tmp/Image-CP2A.260805.005.lz4 /data/local/tmp/eip-pixel8a-forge.zip",
    "chmod 700 /data/local/tmp/eip-ksud",
    "rm -f /data/local/tmp/eip-ksud /data/local/tmp/eip-ksu-init-boot.img /data/local/tmp/eip-ksu-shell-root.img",
  ]);
  const prefixes = [
    "sed -i 's/^DISK_SIZE_BYTES=", "mkdir -p /data/docker/lib /data/docker/run;",
    "if ! grep -q \" /data/docker/lib ext4 \"", "echo 1 > /proc/sys/net/ipv4/ip_forward;",
    "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker pull tonistiigi/binfmt@sha256:",
    "rm -rf /data/eip-cve-src /data/eip-cve-ops;",
    "configured=$(sed -n \"s/^DISK_SIZE_BYTES=//p\"",
    "rm -rf /data/local/tmp/eip-source-ops-",
    "mkdir -p /data/local/tmp/eip-source-ops-",
    "chmod 0700 /data/local/tmp/eip-source-ops-",
    "/data/local/tmp/eip-source-ops-",
    "/data/eip-cve-backups/deploy-",
    "chmod 700 /data/local/tmp/eip-ksu-grant-profile;",
    "/data/local/tmp/eip-ksud boot-patch --boot /data/local/tmp/eip-ksu-init-boot.img ",
  ];
  if (!exact.has(command) && !prefixes.some((prefix) => command.startsWith(prefix))) reject();
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pixel-simple-installer-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, "bin");
  const payload = path.join(root, "payload");
  fs.mkdirSync(bin);
  fs.mkdirSync(payload);
  for (const name of ["host-module.zip", "docker-engine.tgz", "kernel.lz4", "stock-boot.img",
    "ksu-init-boot.img", "ksu-manager.apk", "ksu-grant-profile", "forge-control.apk",
    "forge-source.tar", "forge.lock", "ops.tar", "source-ops.tar", "source-ops.txt",
    "install-source-ops-phone.sh", "restore-source-ops-phone.sh", "deployment-manifest.json"]) {
    fs.writeFileSync(path.join(payload, name), "inert installer test payload\n");
  }
  fs.writeFileSync(path.join(payload, "redeploy.sh"),
    '#!/bin/bash\nprintf "%s\\n" "$*" >"$FAKE_REDEPLOY_ARGS"\ntouch "$FAKE_STARTED"\n', { mode: 0o755 });
  const controllerConfig = `sha256:${"d".repeat(64)}`;
  const operatorConfig = `sha256:${"e".repeat(64)}`;
  fs.writeFileSync(path.join(payload, "forge.lock"),
    "LOCK_VERSION=2\n"
    + `PIXEL_REVISION=${"4".repeat(40)}\n`
    + `FORGE_REVISION=${"5".repeat(40)}\n`
    + `FORGE_SOURCE_SHA256=${"f".repeat(64)}\n`
    + `CONTROLLER_IMAGE=ghcr.io/exploitintel/eip-pixel8a-forge-controller@sha256:${"a".repeat(64)}\n`
    + `CONTROLLER_CONFIG_SHA256=${controllerConfig.slice("sha256:".length)}\n`
    + `OPERATOR_IMAGE=ghcr.io/exploitintel/eip-pixel8a-forge-operator@sha256:${"b".repeat(64)}\n`
    + `OPERATOR_CONFIG_SHA256=${operatorConfig.slice("sha256:".length)}\n`);
  const script = path.join(root, "install.sh");
  fs.copyFileSync(installer, script);
  const mock = path.join(root, "fake-tool.mjs");
  fs.writeFileSync(mock, `(${fakeToolMain.toString()})();\n`);
  for (const tool of ["adb", "fastboot", "sleep", "shasum", "unzip", "docker", "curl", "wget", "ssh"]) {
    fs.writeFileSync(path.join(bin, tool),
      `#!/bin/bash\nexec ${quote(process.execPath)} ${quote(mock)} ${quote(tool)} "$@"\n`,
      { mode: 0o755 });
  }
  const callsFile = path.join(root, "calls.jsonl");
  fs.writeFileSync(callsFile, "");
  const dockerRunning = path.join(root, "docker-running");
  fs.writeFileSync(dockerRunning, "running\n");
  const provider = path.join(root, "providers.env");
  fs.writeFileSync(provider, "FIXTURE_SETTING=not-a-credential\n");
  const mergeHelper = path.join(root, "merge-helper");
  fs.writeFileSync(mergeHelper, '#!/bin/bash\nexit "${FAKE_MERGE_STATUS:-0}"\n', { mode: 0o755 });
  const env = {
    ...process.env, BASH_ENV: "", ENV: "", PATH: `${bin}:/usr/bin:/bin`,
    ADB: path.join(bin, "adb"), FASTBOOT: path.join(bin, "fastboot"),
    FAKE_CALLS: callsFile, FAKE_REMOTE_PROVIDER: path.join(root, "remote-provider.env"),
    FAKE_MERGE_HELPER: mergeHelper,
    FAKE_FAIL_MATCH: "", FAKE_FAIL_STATUS: "23", FAKE_DELAY_MATCH: "",
    FAKE_DELAY_MILLIS: "0", FAKE_MERGE_STATUS: "0",
    FAKE_FAST_HEARTBEAT: "0",
    FAKE_DELAY_RELEASE: "", FAKE_DELAY_READY: "",
    FAKE_STARTED: path.join(root, "started"), FAKE_UI_STARTED: path.join(root, "ui-started"),
    FAKE_DOCKER_RUNNING: dockerRunning, FAKE_STATUS_MODE: "ready", FAKE_UI_STATUS_MODE: "ready",
    FAKE_EXISTING_INSTALL: "0",
    FAKE_HOST_MODULE_CURRENT: "1",
    FAKE_PARK_PENDING: path.join(root, "park-pending"), FAKE_PARKED: path.join(root, "parked"),
    FAKE_REDEPLOY_ARGS: path.join(root, "redeploy-args"),
    FAKE_FORGE_STATE_EXISTS: "1",
    FAKE_LOADED_CONTROLLER_ID: controllerConfig,
    FAKE_LOADED_OPERATOR_ID: operatorConfig,
    FAKE_BAD_PAYLOAD: "",
    FAKE_ROOT_AVAILABLE: "1",
    FAKE_SHELL_ROOT_SIZE: "8388608",
    FAKE_DEVICE: "akita",
    FAKE_FASTBOOT_PRODUCT: "akita",
    FAKE_FINGERPRINT: "google/akita/akita:17/CP2A.260805.005/15828068:user/release-keys",
    FAKE_ANDROID_VERSION: "17",
    FAKE_SECURITY_PATCH: "2026-08-05",
  };
  const calls = () => fs.readFileSync(callsFile, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
  const run = (args = [], overrides = {}) => spawnSync("/bin/bash",
    [script, "--serial", "TEST-SERIAL", ...args],
    { env: { ...env, ...overrides }, encoding: "utf8", timeout: 30_000 });
  return { root, script, env, calls, run, provider };
}

test("installer defaults only new Forge state to Ollama.com", (t) => {
  const existing = fixture(t);
  const existingResult = existing.run([], { FAKE_EXISTING_INSTALL: "1" });
  assert.equal(existingResult.status, 0, existingResult.stderr);
  assert.ok(!existing.calls().some((call) => call.command === "/data/eip-cve-ops/set-ollama.sh https://ollama.com"));

  const fresh = fixture(t);
  const freshResult = fresh.run([], { FAKE_FORGE_STATE_EXISTS: "0" });
  assert.equal(freshResult.status, 0, freshResult.stderr);
  const commands = fresh.calls().map((call) => call.command).filter(Boolean);
  const bootstrap = commands.indexOf("/data/eip-cve-ops/eip.sh bootstrap");
  const cloudDefault = commands.indexOf("/data/eip-cve-ops/set-ollama.sh https://ollama.com");
  assert.ok(bootstrap >= 0 && cloudDefault > bootstrap,
    "fresh installs must apply the Pixel cloud default after Forge bootstrap");
});

test("installer pulls the locked controller digest and tags its verified config", (t) => {
  const item = fixture(t);
  const result = item.run();
  assert.equal(result.status, 0, result.stderr);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(commands.includes("DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker "
    + `pull ghcr.io/exploitintel/eip-pixel8a-forge-controller@sha256:${"a".repeat(64)}`));
  assert.ok(commands.includes("DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker "
    + `tag ghcr.io/exploitintel/eip-pixel8a-forge-controller@sha256:${"a".repeat(64)} eip-cve-controller:local`));
});

test("installer pulls the locked operator digest and tags its verified config", (t) => {
  const item = fixture(t);
  const result = item.run();
  assert.equal(result.status, 0, result.stderr);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(commands.includes("DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker "
    + `pull ghcr.io/exploitintel/eip-pixel8a-forge-operator@sha256:${"b".repeat(64)}`));
  assert.ok(commands.includes("DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker "
    + `tag ghcr.io/exploitintel/eip-pixel8a-forge-operator@sha256:${"b".repeat(64)} eip-operator-shell:phone`));
});

test("installer rebases managed skills after the new WebUI starts and before chat", (t) => {
  const item = fixture(t);
  const result = item.run();
  assert.equal(result.status, 0, result.stderr);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  const ui = commands.indexOf("/data/eip-cve-ops/eip.sh up --force-recreate --no-deps ui");
  const release = commands.indexOf("/data/eip-cve-ops/eip.sh skills-release");
  const fullStart = commands.indexOf("/data/eip-cve-ops/eip-hostctl.sh start");
  const source = commands.findIndex((command) => command.startsWith("rm -rf /data/eip-cve-src"));
  assert.ok(source >= 0 && ui > source && release > ui && fullStart > release,
    "fresh source must be installed before UI and managed skills must release before chat starts");
});

test("installer cleans up an unready candidate WebUI so the update can be retried", (t) => {
  const item = fixture(t);
  const result = item.run([], { FAKE_UI_STATUS_MODE: "never-ready" });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /WebUI did not become healthy/);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(commands.includes("/data/eip-cve-ops/eip.sh logs --no-color --tail 40 ui"));
  assert.ok(commands.includes("/data/eip-cve-ops/eip.sh down"));
  assert.ok(!commands.includes("/data/eip-cve-ops/eip.sh skills-release"));
  assert.ok(!commands.includes("/data/eip-cve-ops/eip-hostctl.sh start"));
});

test("installer cleans up a failed managed-skills release before full start", (t) => {
  const item = fixture(t);
  const result = item.run([], { FAKE_FAIL_MATCH: "skills-release" });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /managed-skills update failed/);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(commands.includes("/data/eip-cve-ops/eip.sh down"));
  assert.ok(!commands.includes("/data/eip-cve-ops/eip-hostctl.sh start"));
});

test("installer refuses a controller pull with the wrong config ID", (t) => {
  const item = fixture(t);
  const result = item.run([], {
    FAKE_EXISTING_CONTROLLER_ID: `sha256:${"c".repeat(64)}`,
    FAKE_LOADED_CONTROLLER_ID: `sha256:${"a".repeat(64)}`,
  });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /controller:local downloaded the wrong image ID/);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(!commands.some((command) => command.includes("docker tag")));
  expectNoCompletion(result, item.calls());
});

test("installer refuses an operator pull with the wrong config ID", (t) => {
  const item = fixture(t);
  const result = item.run([], {
    FAKE_EXISTING_OPERATOR_ID: `sha256:${"c".repeat(64)}`,
    FAKE_LOADED_OPERATOR_ID: `sha256:${"a".repeat(64)}`,
  });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /operator-shell:phone downloaded the wrong image ID/);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(!commands.some((command) => command.endsWith(" eip-operator-shell:phone")));
  expectNoCompletion(result, item.calls());
});

test("existing-install update preserves the disk and uses the transactional release path", (t) => {
  const item = fixture(t);
  const result = item.run([], { FAKE_EXISTING_INSTALL: "1" });
  assert.equal(result.status, 0, result.stderr);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  assert.ok(commands.includes("DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker "
    + `tag ghcr.io/exploitintel/eip-pixel8a-forge-controller@sha256:${"a".repeat(64)} eip-cve-controller:phone`));
  assert.ok(commands.includes("DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker "
    + `tag ghcr.io/exploitintel/eip-pixel8a-forge-operator@sha256:${"b".repeat(64)} eip-operator-shell:candidate`));
  assert.ok(commands.includes("/data/eip-cve-ops/eip-hostctl.sh park-when-idle"));
  const park = commands.indexOf("/data/eip-cve-ops/eip-hostctl.sh reconcile");
  const restart = commands.lastIndexOf("/data/docker/bin/hostctl start");
  assert.ok(restart > park, "Docker must restart after Forge reaches its parked state");
  const cleanup = commands.findIndex((command) => command?.startsWith("rm -rf /data/local/tmp/eip-source-ops-"));
  const shellMkdir = commands.findIndex((command) => command?.startsWith("mkdir -p /data/local/tmp/eip-source-ops-"));
  assert.ok(cleanup >= 0 && shellMkdir > cleanup,
    "ADB shell must create its upload directory after root removes stale staging");
  assert.ok(commands.some((command) => command?.startsWith("/data/local/tmp/eip-source-ops-")));
  assert.ok(!commands.some((command) => command?.startsWith("sed -i 's/^DISK_SIZE_BYTES=")));
  assert.ok(!commands.some((command) => command?.startsWith("rm -rf /data/eip-cve-src")));
  assert.match(fs.readFileSync(item.env.FAKE_REDEPLOY_ARGS, "utf8"), /--parked/);
});

test("existing-install update does not require fresh-install firmware or host payloads", (t) => {
  const item = fixture(t);
  for (const name of ["docker-engine.tgz", "stock-boot.img", "ksu-init-boot.img", "ksu-manager.apk"]) {
    fs.rmSync(path.join(item.root, "payload", name));
  }
  const result = item.run([], { FAKE_EXISTING_INSTALL: "1" });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!item.calls().some((call) => call.tool === "fastboot"));
  assert.equal(result.stdout.trim().split("\n").at(-1), "READY");
});

async function runUntilHeartbeat(item, overrides, heartbeat) {
  const ready = path.join(item.root, "delay-ready");
  const release = path.join(item.root, "delay-release");
  const child = spawn("/bin/bash", [item.script, "--serial", "TEST-SERIAL"], {
    env: { ...item.env, ...overrides, FAKE_FAST_HEARTBEAT: "1",
      FAKE_DELAY_READY: ready, FAKE_DELAY_RELEASE: release },
    detached: true, stdio: ["ignore", "pipe", "pipe"],
  });
  const killGroup = () => {
    if (!child.pid) return;
    try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  };
  let stdout = "", stderr = "", waitingOutput = "";
  let observed = false, timedOut = false;
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (!observed && fs.existsSync(ready)) {
      waitingOutput += chunk;
      if (heartbeat.test(waitingOutput)) {
        observed = true;
        fs.writeFileSync(release, "heartbeat observed\n");
      }
    }
  });
  const timeout = setTimeout(() => { timedOut = true; killGroup(); }, 30_000);
  const result = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (status, signal) => resolve({ status, signal, stdout, stderr }));
  }).finally(() => { clearTimeout(timeout); killGroup(); });
  assert.ok(!timedOut, `fixture installer timed out: ${stderr}`);
  assert.ok(observed, `expected heartbeat while the mock command was waiting: ${stderr}`);
  assert.ok(item.calls().some((call) => call.event === "delay-released"));
  return result;
}

function expectNoCompletion(result, calls) {
  assert.doesNotMatch(result.stdout, /^READY$/m);
  assert.ok(!calls.some((call) => call.verb === "install"), "failure must precede app installation");
  assert.ok(!calls.some((call) => call.command?.includes("eip-hostctl.sh start")),
    "failure must precede Forge start");
  assert.ok(!calls.some((call) => call.command?.startsWith("am start ")),
    "failure must precede opening the app");
}

test("installer rejects missing option values before any device call", (t) => {
  for (const option of ["--serial", "--disk-gib", "--provider-env"]) {
    for (const value of [[], [""], ["--wipe"]]) {
      const item = fixture(t);
      const result = item.run([option, ...value]);
      assert.equal(result.status, 1, `${option}: ${result.stderr}`);
      assert.ok(result.stderr.includes(option), result.stderr);
      assert.match(result.stderr, /(?:value|requires?|missing)/i);
      assert.deepEqual(item.calls(), [], "invalid arguments must fail before adb or progress begins");
    }
  }
});

test("installer rejects an update-unsafe 8 GiB disk before any device call", (t) => {
  const item = fixture(t);
  const result = item.run(["--disk-gib", "8"]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /--disk-gib must be 16, 32, or 64/);
  assert.deepEqual(item.calls(), []);
});

test("wipe verifies the exact Android target before erasing data", (t) => {
  const item = fixture(t);
  const result = item.run(["--wipe"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^WIPE COMPLETE$/m);
  assert.doesNotMatch(result.stdout, /^READY$/m);
  const calls = item.calls();
  const reboot = calls.findIndex((call) => call.tool === "adb" && call.verb === "reboot");
  const wipe = calls.findIndex((call) => call.tool === "fastboot" && call.args.at(-1) === "-w");
  const product = calls.findIndex((call) => call.tool === "fastboot"
    && call.args.slice(2).join(" ") === "getvar product");
  const fastbootReboot = calls.findIndex((call) => call.tool === "fastboot"
    && call.args.at(-1) === "reboot");
  const identity = calls.filter((call) => call.tool === "adb"
    && call.command?.startsWith("getprop "));
  assert.equal(identity.length, 4);
  assert.ok(reboot > calls.indexOf(identity.at(-1))
    && product > reboot && wipe > product && fastbootReboot > wipe);
});

test("wipe refuses a different fastboot product before erasing data", (t) => {
  const item = fixture(t);
  const result = item.run(["--wipe"], { FAKE_FASTBOOT_PRODUCT: "husky" });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /unsupported fastboot product: husky/);
  assert.ok(!item.calls().some((call) => call.tool === "fastboot" && call.args.at(-1) === "-w"));
});

test("wipe and install reject unsupported Android targets before a bootloader action", (t) => {
  const mismatches = [
    ["device", { FAKE_DEVICE: "husky" }, /unsupported device/i],
    ["build", { FAKE_FINGERPRINT: "google/akita/akita:17/WRONG/1:user/release-keys" }, /unsupported Android build/i],
    ["Android version", { FAKE_ANDROID_VERSION: "16" }, /unsupported Android version/i],
    ["security patch", { FAKE_SECURITY_PATCH: "2026-07-05" }, /unsupported security patch/i],
  ];
  for (const mode of ["wipe", "install"]) {
    for (const [label, overrides, message] of mismatches) {
      const item = fixture(t);
      const result = item.run(mode === "wipe" ? ["--wipe"] : [], overrides);
      assert.equal(result.status, 1, `${mode} ${label}: ${result.stderr}`);
      assert.match(result.stderr, message);
      const calls = item.calls();
      assert.ok(!calls.some((call) => call.tool === "fastboot"), `${mode} ${label}: fastboot called`);
      assert.ok(!calls.some((call) => call.tool === "adb" && call.verb === "reboot"),
        `${mode} ${label}: phone rebooted`);
      assert.ok(!calls.some((call) => call.tool === "adb" && call.verb === "push"),
        `${mode} ${label}: payload pushed`);
    }
  }
});

test("installer rejects a changed bootstrap payload before contacting the phone", (t) => {
  for (const [name, message] of [
    ["stock-boot.img", /stock boot image has the wrong SHA-256/],
    ["ksu-init-boot.img", /KernelSU init_boot image has the wrong SHA-256/],
    ["ksu-manager.apk", /KernelSU Manager APK has the wrong SHA-256/],
  ]) {
    const item = fixture(t);
    const result = item.run([], { FAKE_BAD_PAYLOAD: name });
    assert.equal(result.status, 1, `${name}: ${result.stderr}`);
    assert.match(result.stderr, message);
    assert.ok(!item.calls().some((call) => call.tool === "fastboot"));
    assert.ok(!item.calls().some((call) => call.tool === "adb" && call.verb === "push"));
  }
});

test("root bootstrap refuses a wrong-size prepared init_boot before entering fastboot", (t) => {
  const item = fixture(t);
  const result = item.run([], { FAKE_ROOT_AVAILABLE: "0", FAKE_SHELL_ROOT_SIZE: "7" });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /KernelSU bootstrap image has the wrong size/);
  const calls = item.calls();
  assert.ok(!calls.some((call) => call.command?.startsWith("/data/local/tmp/eip-ksud boot-patch ")));
  assert.ok(!calls.some((call) => call.tool === "fastboot"));
  assert.ok(!calls.some((call) => call.tool === "adb" && call.verb === "reboot"));
});

test("installer delegates storage, routing, and Docker lifecycle to Pixel 8a hostctl", () => {
  const source = fs.readFileSync(installer, "utf8");
  assert.match(source, /\/data\/docker\/bin\/hostctl disk-init --size-bytes/);
  assert.match(source, /\/data\/docker\/bin\/hostctl start/);
  for (const forbidden of ["losetup", "mke2fs", "ip rule add", "iptables -I",
    "dockerd.sh --runtime-only", "lookup 1016"]) {
    assert.ok(!source.includes(forbidden), `installer must not contain raw host operation: ${forbidden}`);
  }
});

test("firmware preparation installs the qualified KernelSU LKM payload", () => {
  const source = fs.readFileSync(firmwarePreparer, "utf8");
  assert.match(source, /boot-patch --boot \$REMOTE_INIT --kmi android14-6[.]1 --allow-shell /);
  assert.ok(!source.includes("--no-install"),
    "config-only patching omits the KernelSU LKM payload and cannot produce the qualified image");
});

test("fresh host installation uses the module, qualified kernel, hostctl, and one reboot", (t) => {
  const item = fixture(t);
  const result = item.run([], { FAKE_HOST_MODULE_CURRENT: "0" });
  assert.equal(result.status, 0, result.stderr);
  const calls = item.calls();
  const commands = calls.map((call) => call.command).filter(Boolean);
  const moduleInstall = commands.indexOf("/data/adb/ksud module install /data/local/tmp/eip-pixel8a-forge.zip");
  const diskInit = commands.indexOf("/data/docker/bin/hostctl disk-init --size-bytes 68719476736");
  const kernelInstall = commands.indexOf("KSU=true KSU_VER=3.3.0 KSU_VER_CODE=33214 KSU_RUNTIME_MODE=lkm /data/adb/modules_update/eip-pixel8a-forge/bin/kernelctl install INSTALL:CP2A.260805.005:_a");
  const reboot = calls.findIndex((call) => call.tool === "adb" && call.verb === "reboot"
    && call.command === "");
  assert.ok(moduleInstall >= 0 && diskInit > moduleInstall && kernelInstall > diskInit,
    "the module must install before managed disk and kernel setup");
  assert.ok(reboot >= 0, "the host install must reboot once before Docker starts");
  assert.equal(calls.filter((call) => call.tool === "adb" && call.verb === "reboot"
    && call.command === "").length, 1);
  assert.equal(result.stdout.trim().split("\n").at(-1), "READY");
});

for (const suppliedProviders of [false, true]) {
  test(`installer finishes with READY and a useful summary (${suppliedProviders ? "supplied" : "no"} providers)`, (t) => {
    const item = fixture(t);
    const result = item.run(suppliedProviders ? ["--provider-env", item.provider] : []);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim().split("\n").at(-1), "READY");
    const output = result.stdout + result.stderr;
    for (const field of [/^Docker[:=]\s*running$/im, /^(?:Web)?UI[:=]\s*healthy$/im,
      /^(?:Agent )?chat[:=]\s*healthy$/im]) {
      assert.match(result.stdout, field);
    }
    assert.match(result.stdout, /Forge WebUI login\n  Username: operator\n  Password: fixture-webui-password/);
    assert.match(result.stdout, /eip\.sh\\ password/);
    assert.match(output, /open[^\n]*Forge Control|Forge Control[^\n]*open/i);
    assert.match(output, suppliedProviders
      ? /provider[^\n]*(?:installed|merged|imported)/i
      : /provider[^\n]*(?:not supplied|not provided|unchanged|skipped|none)/i);
    assert.deepEqual(item.calls().filter((call) => call.event === "merge-finished"),
      suppliedProviders ? [{ event: "merge-finished", status: 0, cleaned: true }] : []);
    assert.ok(item.calls().some((call) => call.command?.startsWith("am start ")));
  });
}

test("provider merge failure preserves exit 42, cleans its file, and stops installation", (t) => {
  const item = fixture(t);
  const result = item.run(["--provider-env", item.provider], { FAKE_MERGE_STATUS: "42" });
  assert.equal(result.status, 42, result.stderr);
  assert.match(result.stderr, /provider/i);
  assert.match(result.stderr, /(?:exit|status|code)[^\n]*42/i);
  assert.deepEqual(item.calls().filter((call) => call.event === "merge-finished"),
    [{ event: "merge-finished", status: 42, cleaned: true }]);
  expectNoCompletion(result, item.calls());
});

test("installer reports the failed stage and actual command exit status", (t) => {
  const item = fixture(t);
  const result = item.run([], { FAKE_FAIL_MATCH: "eip-forge-source.tar", FAKE_FAIL_STATUS: "23" });
  assert.equal(result.status, 23, result.stderr);
  assert.match(result.stderr, /(?:failed|failure)[^\n]*(?:source|Forge)|(?:source|Forge)[^\n]*(?:failed|failure)/i);
  assert.match(result.stderr, /(?:exit|status|code)[^\n]*23/i);
  expectNoCompletion(result, item.calls());
});

test("quiet stages emit a 15-second heartbeat on stderr while stdout stays machine-readable", async (t) => {
  const item = fixture(t);
  const result = await runUntilHeartbeat(item, { FAKE_DELAY_MATCH: "pull tonistiigi/binfmt@" },
    /Still working:[^\n]*(?:architecture|handler)/i);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(item.calls().some((call) => call.event === "delay-started"), "fixture must exercise a quiet operation");
  assert.ok(item.calls().some((call) => call.tool === "sleep" && call.args[0] === "15"),
    "heartbeat cadence must remain 15 seconds even though fixture sleep is shortened");
  assert.match(result.stderr, /still[^\n]*(?:working|waiting|running)|(?:elapsed|in progress)/i);
  assert.match(result.stderr, /Still working:[^\n]*(?:architecture|handler)/i,
    "the deliberately quiet download stage must emit a heartbeat");
  assert.doesNotMatch(result.stdout, /still[^\n]*(?:working|waiting|running)|(?:elapsed|in progress)/i);
  assert.doesNotMatch(result.stdout, /^\[\d+m\d+s\]|^(?:Using existing |Loading |Installing provider configuration)/m);
  assert.equal(result.stdout.trim().split("\n").at(-1), "READY");
});

test("delayed image pull keeps heartbeat out of captured output", async (t) => {
  const item = fixture(t);
  const result = await runUntilHeartbeat(item, {
    FAKE_DELAY_MATCH: "pull ghcr.io/exploitintel/eip-pixel8a-forge-controller@",
  }, /Still working:[^\n]*Downloading eip-cve-controller:local/);
  assert.equal(result.status, 0, result.stderr);
  const commands = item.calls().map((call) => call.command).filter(Boolean);
  const pullIndex = commands.findIndex((command) => command.includes("pull ghcr.io/exploitintel/eip-pixel8a-forge-controller@"));
  const tagIndex = commands.findIndex((command) => command.includes(" eip-cve-controller:local"));
  assert.ok(pullIndex >= 0 && tagIndex > pullIndex, "the verified digest pull must precede its local tag");
  assert.ok(item.calls().some((call) => call.event === "delay-started"));
  assert.match(result.stderr, /Still working:[^\n]*Downloading eip-cve-controller:local/);
  assert.doesNotMatch(result.stdout, /Still working:|^\[\d+m\d+s\]/m);
  assert.equal(result.stdout.trim().split("\n").at(-1), "READY");
});

test("readiness exhaustion and failed status commands retain diagnostics without claiming READY", (t) => {
  for (const mode of ["never-ready", "failed"]) {
    const item = fixture(t);
    const result = item.run([], { FAKE_STATUS_MODE: mode });
    assert.equal(result.status, 1, `${mode}: ${result.stderr}`);
    assert.match(result.stderr, /Last Forge status:/);
    assert.match(result.stderr, mode === "never-ready" ? /system=degraded/ : /system=ready/);
    assert.match(result.stderr, /failed during[^\n]*readiness/i);
    assert.doesNotMatch(result.stdout, /^READY$/m);
    const calls = item.calls();
    assert.equal(calls.filter((call) => call.command === "/data/eip-cve-ops/eip-hostctl.sh status").length,
      61, "readiness must stop after the UI check and fixed 60 attempts");
    assert.ok(calls.some((call) => call.verb === "install"), "fixture must reach app installation");
    assert.ok(calls.some((call) => call.command === "/data/eip-cve-ops/eip-hostctl.sh start"));
    assert.ok(calls.some((call) => call.command === "/data/eip-cve-ops/eip-hostctl.sh logs"));
    assert.ok(!calls.some((call) => call.command?.startsWith("am start ")),
      "neither an unready host nor READY output from a failed status command may open the app");
  }
});

test("interrupting a quiet operation reports its stage and does not claim completion", async (t) => {
  const item = fixture(t);
  const child = spawn("/bin/bash", [item.script, "--serial", "TEST-SERIAL"], {
    env: { ...item.env, FAKE_DELAY_MATCH: "eip-forge-source.tar", FAKE_DELAY_MILLIS: "5000" },
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  let interrupted = false;
  let interval;
  let timeout;
  const result = await new Promise((resolve, reject) => {
    interval = setInterval(() => {
      if (!interrupted && item.calls().some((call) => call.event === "delay-started")) {
        interrupted = true;
        process.kill(-child.pid, "SIGINT");
      }
    }, 20);
    timeout = setTimeout(() => {
      process.kill(-child.pid, "SIGKILL");
      reject(new Error("fixture installer did not respond to interruption"));
    }, 10_000);
    child.on("error", reject);
    child.on("close", (status, signal) => resolve({ status, signal, stdout, stderr }));
  }).finally(() => {
    clearInterval(interval);
    clearTimeout(timeout);
  });
  assert.ok(interrupted, "test must interrupt an actual delayed mock command");
  assert.equal(result.status, 130, result.stderr);
  assert.match(result.stderr, /(?:exit|status|code)[^\n]*130/i);
  assert.match(result.stderr, /(?:failed|failure)[^\n]*(?:source|Forge)|(?:source|Forge)[^\n]*(?:failed|failure)/i);
  expectNoCompletion(result, item.calls());
});
