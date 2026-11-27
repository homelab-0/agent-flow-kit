#!/usr/bin/env node
// Thin launcher: npm installs only the platform package that matches this
// machine (os/cpu in its package.json), and this file runs its binary.
// Nothing is downloaded at install time.
"use strict";

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const platforms = {
  "linux-x64": "@homelab0/afk-linux-x64",
  "linux-arm64": "@homelab0/afk-linux-arm64",
  "darwin-x64": "@homelab0/afk-darwin-x64",
  "darwin-arm64": "@homelab0/afk-darwin-arm64",
  "win32-x64": "@homelab0/afk-win32-x64",
  "win32-arm64": "@homelab0/afk-win32-arm64",
};

function binaryPath() {
  const key = `${process.platform}-${process.arch}`;
  const pkg = platforms[key];
  if (!pkg) {
    throw new Error(`afk has no build for ${key}. Builds exist for: ${Object.keys(platforms).join(", ")}.`);
  }
  const exe = process.platform === "win32" ? "afk.exe" : "afk";
  try {
    return path.join(path.dirname(require.resolve(`${pkg}/package.json`)), "bin", exe);
  } catch {
    throw new Error(
      `afk: ${pkg} is not installed. It is an optional dependency of @homelab0/afk; ` +
        `reinstall without --no-optional / --omit=optional.`,
    );
  }
}

let bin;
try {
  bin = binaryPath();
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

const res = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (res.error) {
  console.error(`afk: could not start ${bin}: ${res.error.message}`);
  process.exit(1);
}
if (res.signal) {
  process.kill(process.pid, res.signal);
}
process.exit(res.status ?? 1);
