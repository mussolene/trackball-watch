#!/usr/bin/env node
/**
 * Sync desktop host version fields from git tags (semver).
 *
 * Priority:
 *   1. GITHUB_REF=refs/tags/v* (exact tag in CI)
 *   2. GITHUB_REF_NAME=v* (some runners)
 *   3. git describe --tags --match "v*"
 *
 * When HEAD is N commits after tag vA.B.C, version becomes A.B.C-dev.N (Cargo-safe semver).
 *
 * Skip with SKIP_SYNC_VERSION=1 (e.g. local builds when you do not want file churn).
 * Skip cargo check with SKIP_CARGO_CHECK=1 if needed; otherwise a stub `dist/index.html`
 * is created when missing so `cargo check` works without a Vite build (e.g. CI).
 */
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..");

function run(cmd, opts = {}) {
  return execSync(cmd, { encoding: "utf8", cwd: repoRoot, ...opts }).trim();
}

function resolveVersion() {
  const ref = process.env.GITHUB_REF || "";
  if (ref.startsWith("refs/tags/v")) {
    return ref.slice("refs/tags/v".length);
  }
  const refName = process.env.GITHUB_REF_NAME || "";
  if (refName.startsWith("v") && /^\d+\.\d+\.\d+/.test(refName.slice(1))) {
    return refName.slice(1);
  }

  try {
    const tag = run('git describe --tags --match "v*" --abbrev=0');
    const base = tag.replace(/^v/, "");
    const full = run('git describe --tags --match "v*" --long');
    const m = full.match(/^v(\d+\.\d+\.\d+)(?:-(\d+)-g([0-9a-f]+))?$/);
    if (!m) {
      return base;
    }
    if (!m[2]) {
      return m[1];
    }
    return `${m[1]}-dev.${m[2]}`;
  } catch {
    const short = run("git rev-parse --short HEAD");
    return `0.0.0-dev.${short}`;
  }
}

function patchCargoToml(path, version) {
  const raw = readFileSync(path, "utf8");
  const lines = raw.split(/\n/);
  let inPackage = false;
  let done = false;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t === "[package]") {
      inPackage = true;
      continue;
    }
    if (inPackage && t.startsWith("[") && t !== "[package]") {
      break;
    }
    if (inPackage && /^version\s*=\s*"/.test(t)) {
      lines[i] = `version = "${version}"`;
      done = true;
      break;
    }
  }
  if (!done) {
    throw new Error(`sync-version: could not find [package] version in ${path}`);
  }
  writeFileSync(path, lines.join("\n"));
}

function writeJson(path, mutator) {
  const j = JSON.parse(readFileSync(path, "utf8"));
  mutator(j);
  writeFileSync(path, JSON.stringify(j, null, 2) + "\n");
}

const FRONTEND_DIST_STUB =
  "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body></body></html>\n";

/** Tauri `generate_context!` requires `build.frontendDist` to exist at compile time; CI has no Vite build. */
function ensureFrontendDistStubForCargoCheck(hostDir, coreDir) {
  const distDir = resolve(hostDir, "dist");
  const indexPath = join(distDir, "index.html");
  const fromManifest = resolve(coreDir, "..", "dist");
  if (resolve(distDir) !== resolve(fromManifest)) {
    throw new Error(
      `sync-version: frontendDist path mismatch: ${distDir} vs ${fromManifest}`
    );
  }
  mkdirSync(distDir, { recursive: true });
  const inCI =
    process.env.GITHUB_ACTIONS === "true" || process.env.CI === "true";
  if (inCI || !existsSync(indexPath)) {
    writeFileSync(indexPath, FRONTEND_DIST_STUB);
    console.log(
      "sync-version: wrote stub dist/index.html so cargo check can run (no Vite build in tree)"
    );
  }
}

function main() {
  if (process.env.SKIP_SYNC_VERSION === "1") {
    console.log("sync-version: skipped (SKIP_SYNC_VERSION=1)");
    return;
  }

  const version = resolveVersion();
  console.log(`sync-version: ${version}`);

  const hostDir = join(repoRoot, "apps", "host-desktop");
  const coreDir = join(hostDir, "src-tauri");

  patchCargoToml(join(coreDir, "Cargo.toml"), version);
  writeJson(join(coreDir, "tauri.conf.json"), (j) => {
    j.version = version;
  });
  writeJson(join(hostDir, "package.json"), (j) => {
    j.version = version;
  });
  writeJson(join(hostDir, "package-lock.json"), (j) => {
    j.version = version;
    if (j.packages && j.packages[""]) {
      j.packages[""].version = version;
    }
  });

  if (process.env.SKIP_CARGO_CHECK === "1") {
    console.log("sync-version: skipped cargo check (SKIP_CARGO_CHECK=1)");
    return;
  }

  ensureFrontendDistStubForCargoCheck(hostDir, coreDir);
  run("cargo check -q", { cwd: coreDir });
}

main();
