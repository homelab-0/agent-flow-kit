#!/usr/bin/env node
// Builds the npm packages for a release from GoReleaser's dist/ folder.
//
//   node npm/build.mjs <version> [dist] [out]
//
// Writes one package per platform (out/afk-<os>-<cpu>/) holding that
// platform's binary, and the wrapper package (out/afk/) whose
// optionalDependencies pin them all to <version>. Publish the platform
// packages first, then the wrapper.
import { chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const [version, dist = "dist", out = join(here, "out")] = process.argv.slice(2);
if (!version || !/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version)) {
  console.error("usage: node npm/build.mjs <version without v> [dist] [out]");
  process.exit(2);
}

const goToNode = {
  os: { linux: "linux", darwin: "darwin", windows: "win32" },
  arch: { amd64: "x64", arm64: "arm64" },
};

const wrapper = JSON.parse(readFileSync(join(here, "afk", "package.json"), "utf8"));
const artifacts = JSON.parse(readFileSync(join(dist, "artifacts.json"), "utf8"));
const binaries = artifacts.filter((a) => a.type === "Binary" && a.extra?.ID === "afk");
if (binaries.length === 0) {
  console.error(`no afk binaries in ${join(dist, "artifacts.json")}`);
  process.exit(1);
}

rmSync(out, { recursive: true, force: true });
const optional = {};
for (const b of binaries) {
  const os = goToNode.os[b.goos];
  const cpu = goToNode.arch[b.goarch];
  if (!os || !cpu) continue;
  const name = `@homelab0/afk-${os}-${cpu}`;
  const dir = join(out, `afk-${os}-${cpu}`);
  const exe = os === "win32" ? "afk.exe" : "afk";
  mkdirSync(join(dir, "bin"), { recursive: true });
  copyFileSync(b.path, join(dir, "bin", exe));
  chmodSync(join(dir, "bin", exe), 0o755);
  writeFileSync(
    join(dir, "package.json"),
    JSON.stringify(
      {
        name,
        version,
        description: `The afk binary for ${os}-${cpu}. Install @homelab0/afk instead.`,
        license: wrapper.license,
        homepage: wrapper.homepage,
        repository: { ...wrapper.repository, directory: "npm" },
        os: [os],
        cpu: [cpu],
        files: [`bin/${exe}`],
        preferUnplugged: true,
      },
      null,
      2,
    ) + "\n",
  );
  copyFileSync(join(here, "..", "LICENSE"), join(dir, "LICENSE"));
  optional[name] = version;
}

const wdir = join(out, "afk");
mkdirSync(join(wdir, "bin"), { recursive: true });
copyFileSync(join(here, "afk", "bin", "afk.js"), join(wdir, "bin", "afk.js"));
chmodSync(join(wdir, "bin", "afk.js"), 0o755);
copyFileSync(join(here, "..", "LICENSE"), join(wdir, "LICENSE"));
copyFileSync(join(here, "..", "README.md"), join(wdir, "README.md"));
writeFileSync(
  join(wdir, "package.json"),
  JSON.stringify({ ...wrapper, version, optionalDependencies: optional }, null, 2) + "\n",
);
console.log(`built ${Object.keys(optional).length} platform packages and @homelab0/afk ${version} in ${out}`);
