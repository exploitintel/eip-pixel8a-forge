#!/usr/bin/env node
// Fail-closed summary of every live-lane metadata file and durable publication
// intent for eip-hostctl. This runs inside the existing UI container; it never
// reads credentials or contacts a listener.

import fs from "node:fs";
import path from "node:path";

const stateRoot = "/data/eip-cve/state";
const runsRoot = path.join(stateRoot, "runs");
const publicationIntentsRoot = path.join(stateRoot, "publication-intents");
const statusValues = new Set(["running", "exited", "interrupted", "cancelled"]);
const kindValues = new Set(["run", "scout", "qa", "verify"]);
const cvePattern = /^CVE-\d{4}-\d{4,}$/;
const timestampPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
const shaPattern = /^[0-9a-f]{40}$/;
const digestPattern = /^[0-9a-f]{64}$/;
const remoteSegmentPattern = /^[A-Za-z0-9_.-]+$/;
const publicationIntentFields = [
  "baseBranch", "baseSha", "branch", "commit", "cve", "fetchUrl", "phase",
  "pocsRepo", "pr", "publishedAt", "pushUrl", "queueItemSha256", "repository", "schema",
].sort();

function ambiguous() {
  process.stdout.write([
    "work=ambiguous",
    "active_count=unknown",
    "active_kind=unknown",
    "active_cve=unknown",
    "active_phase=unknown",
    "active_started_at=unknown",
    "",
  ].join("\n"));
  process.exit(11);
}

const invocationArguments = process.argv.slice(2);
if (invocationArguments.length > 1 ||
    (invocationArguments.length === 1 && invocationArguments[0] !== "--park-proof")) {
  ambiguous();
}

function readMeta(name) {
  const file = path.join(runsRoot, name);
  let descriptor;
  try {
    const before = fs.lstatSync(file);
    if (!before.isFile() || before.isSymbolicLink() || before.size < 2 || before.size > 1024 * 1024) {
      return null;
    }
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.size < 2 || opened.size > 1024 * 1024) return null;
    const value = JSON.parse(fs.readFileSync(descriptor, "utf8"));
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    if (!statusValues.has(value.status)) return null;
    return value;
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { /* already closed */ }
    }
  }
}

function readQueue() {
  const file = path.join(stateRoot, "queue.json");
  let descriptor;
  let observed = false;
  try {
    const before = fs.lstatSync(file);
    observed = true;
    if (!before.isFile() || before.isSymbolicLink() || before.size < 2 || before.size > 4 * 1024 * 1024) {
      return null;
    }
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.size < 2 || opened.size > 4 * 1024 * 1024) return null;
    const value = JSON.parse(fs.readFileSync(descriptor, "utf8"));
    if (value === null || typeof value !== "object" || Array.isArray(value) || !Array.isArray(value.items)) {
      return null;
    }
    if (value.items.some((item) => item === null || typeof item !== "object" || Array.isArray(item))) return null;
    return value;
  } catch (error) {
    if (error?.code === "ENOENT" && !observed) return { items: [] };
    return null;
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { /* already closed */ }
    }
  }
}

function remoteSegmentsIdentity(candidate) {
  if (candidate.endsWith(".git")) candidate = candidate.slice(0, -".git".length);
  const segments = candidate.split("/");
  if (segments.length !== 3) return null;
  for (const segment of segments) {
    if (segment === "" || segment === "." || segment === ".." || !remoteSegmentPattern.test(segment)) {
      return null;
    }
  }
  return segments.join("/").toLowerCase();
}

function normalizeRemote(value, { allowIdentity = true } = {}) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "" || trimmed !== value || trimmed.includes("?")) return null;

  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    let url;
    try {
      url = new URL(trimmed);
    } catch {
      return null;
    }
    if (url.search !== "" || url.hash !== "" || url.password !== "") return null;
    if (url.protocol === "https:") {
      if (url.username !== "" || (url.port !== "" && url.port !== "443")) return null;
    } else if (url.protocol === "ssh:") {
      if (url.username !== "git") return null;
    } else {
      return null;
    }
    return remoteSegmentsIdentity(`${url.hostname.toLowerCase()}/${url.pathname.replace(/^\/+/, "")}`);
  }

  const firstSlash = trimmed.indexOf("/");
  const colon = trimmed.indexOf(":");
  if (colon !== -1 && (firstSlash === -1 || colon < firstSlash)) {
    const hostPart = trimmed.slice(0, colon);
    const pathPart = trimmed.slice(colon + 1);
    const at = hostPart.indexOf("@");
    if (at === -1 || hostPart.slice(0, at) !== "git") return null;
    return remoteSegmentsIdentity(`${hostPart.slice(at + 1).toLowerCase()}/${pathPart}`);
  }

  return allowIdentity ? remoteSegmentsIdentity(trimmed) : null;
}

function validPrUrl(value, repository) {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    const match = /^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/[1-9][0-9]*$/.exec(url.pathname);
    return url.protocol === "https:" && url.username === "" && url.password === ""
      && (url.port === "" || url.port === "443") && url.search === "" && url.hash === ""
      && match !== null
      && `${url.hostname}/${match[1]}/${match[2]}`.toLowerCase() === repository;
  } catch {
    return false;
  }
}

function validPublicationIntent(intent, cve) {
  if (intent === null || typeof intent !== "object" || Array.isArray(intent)) return false;
  const fields = Object.keys(intent).sort();
  if (fields.length !== publicationIntentFields.length ||
      fields.some((field, index) => field !== publicationIntentFields[index])) return false;
  const expectedPocsRepo = process.env.EIP_POCS_REPO;
  return intent.schema === "eip-cve-publication-intent-v1"
    && intent.cve === cve && cvePattern.test(cve)
    && ["prepared", "branch", "published"].includes(intent.phase)
    && typeof expectedPocsRepo === "string" && path.isAbsolute(expectedPocsRepo)
    && intent.pocsRepo === expectedPocsRepo
    && normalizeRemote(intent.repository) === intent.repository
    && normalizeRemote(intent.fetchUrl, { allowIdentity: false }) === intent.repository
    && normalizeRemote(intent.pushUrl, { allowIdentity: false }) === intent.repository
    && typeof intent.baseBranch === "string" && intent.baseBranch !== ""
    && typeof intent.branch === "string" && intent.branch !== ""
    && shaPattern.test(intent.baseSha) && shaPattern.test(intent.commit)
    && digestPattern.test(intent.queueItemSha256)
    && (intent.phase !== "published" || validPrUrl(intent.pr, intent.repository))
    && (intent.publishedAt === null || typeof intent.publishedAt === "string");
}

function readPublicationIntent(name, cve) {
  const file = path.join(publicationIntentsRoot, name);
  let descriptor;
  try {
    const before = fs.lstatSync(file);
    if (!before.isFile() || before.isSymbolicLink() || before.size < 2 || before.size > 1024 * 1024) {
      return null;
    }
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.size < 2 || opened.size > 1024 * 1024) return null;
    const intent = JSON.parse(fs.readFileSync(descriptor, "utf8"));
    return validPublicationIntent(intent, cve) ? intent : null;
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      try { fs.closeSync(descriptor); } catch { /* already closed */ }
    }
  }
}

function readPublicationIntents() {
  let before;
  let names;
  try {
    before = fs.lstatSync(publicationIntentsRoot);
    if (!before.isDirectory() || before.isSymbolicLink()) return null;
    names = fs.readdirSync(publicationIntentsRoot).sort();
    const after = fs.lstatSync(publicationIntentsRoot);
    if (!after.isDirectory() || after.isSymbolicLink() ||
        before.dev !== after.dev || before.ino !== after.ino) return null;
  } catch (error) {
    if (error?.code === "ENOENT" && before === undefined) return [];
    return null;
  }

  const intents = [];
  for (const name of names) {
    const match = /^(CVE-\d{4}-\d{4,})\.json$/.exec(name);
    if (match === null) return null;
    const intent = readPublicationIntent(name, match[1]);
    if (intent === null) return null;
    intents.push(intent);
  }
  return intents;
}

function directoryNonEmpty(target) {
  try {
    return fs.readdirSync(target).length > 0;
  } catch {
    return false;
  }
}

function regularFile(target) {
  try {
    return fs.statSync(target).isFile();
  } catch {
    return false;
  }
}

function runPhase(cve) {
  const lab = path.join(stateRoot, "labs", cve);
  if (regularFile(path.join(lab, "publish", "README.md"))) return "publish";
  if (directoryNonEmpty(path.join(lab, "poc"))) return "poc";
  if (directoryNonEmpty(path.join(lab, "lab"))) return "branch";
  if (regularFile(path.join(lab, "INTEL.md"))) return "research";
  return "router";
}

let names;
try {
  names = fs.readdirSync(runsRoot).filter((name) => name.endsWith(".meta.json")).sort();
} catch (error) {
  if (error?.code === "ENOENT") names = [];
  else ambiguous();
}

const active = [];
for (const name of names) {
  const meta = readMeta(name);
  if (meta === null) ambiguous();
  if (meta.status !== "running") continue;

  const kind = meta.kind ?? "run";
  if (!kindValues.has(kind)) ambiguous();
  if (kind !== "scout" && (typeof meta.cve !== "string" || !cvePattern.test(meta.cve))) ambiguous();
  if (kind === "scout" && meta.cve !== null && meta.cve !== undefined &&
      (typeof meta.cve !== "string" || !cvePattern.test(meta.cve))) ambiguous();
  if (typeof meta.startedAt !== "string" || !timestampPattern.test(meta.startedAt) ||
      !Number.isFinite(Date.parse(meta.startedAt))) ambiguous();
  active.push({
    kind,
    cve: meta.cve ?? "none",
    phase: kind === "run" ? runPhase(meta.cve) : kind,
    startedAt: meta.startedAt,
  });
}

const queue = readQueue();
if (queue === null) ambiguous();
const runningQueue = queue.items.filter((item) => item.state === "running");
const activeRuns = active.filter((entry) => entry.kind === "run");
if (runningQueue.length !== activeRuns.length) ambiguous();
for (const item of runningQueue) {
  if (typeof item.cve !== "string" || !cvePattern.test(item.cve) ||
      typeof item.startedAt !== "string" || !timestampPattern.test(item.startedAt)) ambiguous();
  const matches = activeRuns.filter((entry) => entry.cve === item.cve && entry.startedAt === item.startedAt);
  if (matches.length !== 1) ambiguous();
}

const publicationIntents = readPublicationIntents();
if (publicationIntents === null) ambiguous();
for (const intent of publicationIntents) {
  active.push({ kind: "publish", cve: intent.cve, phase: "publish", startedAt: "unknown" });
}

if (active.length === 0) {
  process.stdout.write([
    "work=idle",
    "active_count=0",
    "active_kind=none",
    "active_cve=none",
    "active_phase=none",
    "active_started_at=none",
    "",
  ].join("\n"));
  process.exit(0);
}

if (active.length === 1) {
  const [entry] = active;
  process.stdout.write([
    "work=active",
    "active_count=1",
    `active_kind=${entry.kind}`,
    `active_cve=${entry.cve}`,
    `active_phase=${entry.phase}`,
    `active_started_at=${entry.startedAt}`,
    "",
  ].join("\n"));
  process.exit(10);
}

process.stdout.write([
  "work=active",
  `active_count=${active.length}`,
  "active_kind=multiple",
  "active_cve=multiple",
  "active_phase=multiple",
  "active_started_at=multiple",
  "",
].join("\n"));
process.exit(10);
