import { execFile, execFileSync, spawn } from "node:child_process"
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { homedir } from "node:os"
import { fileURLToPath } from "node:url"
import { createHash } from "node:crypto"

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const cacheRoot = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "agent-flow-kit")
const sessionStart = join(root, "bin", "afk-session-start")
const workerContext = join(root, "worker-context.sh")

function sessionCacheDir(session) {
  if (process.env.AFK_STATUS_CACHE_DIR) return process.env.AFK_STATUS_CACHE_DIR
  const terminal = process.env.ORCA_TERMINAL_HANDLE || ""
  const scopeKind = terminal ? "terminal" : "session"
  const scopeValue = terminal || String(session || "")
  if (!scopeValue) return null
  const scopeDigest = createHash("sha256").update(scopeKind).update("\0").update(scopeValue).digest("hex")
  return join(cacheRoot, "scopes", `${scopeKind}-${scopeDigest}`)
}
function sessionEnvironment(session) {
  const env = { ...process.env }
  delete env.AFK_RUNTIME_SESSION_ID
  if (session) env.AFK_RUNTIME_SESSION_ID = String(session)
  return env
}

function startupTimeout() {
  const configured = Number.parseInt(process.env.AFK_SESSION_START_TIMEOUT_MS || "120000", 10)
  return Number.isFinite(configured) ? Math.min(Math.max(configured, 1000), 180000) : 120000
}
function showUpdateFailure(client, reason) {
  try {
    const shown = client?.tui?.showToast?.({
      body: { title: "AFK updater", message: `AFK UNAVAILABLE[${reason}]`, variant: "warning", duration: 8000 }
    })
    if (shown?.catch) shown.catch(() => {})
  } catch {}
}
function autoUpdatePlatform() { return process.platform }
function reconcileAtStartup(client) {
  const platform = autoUpdatePlatform()
  if (platform !== "linux") {
    showUpdateFailure(client, platform === "darwin" ? "MACOS_SANDBOX_PENDING" : "AUTO_UPDATE_PLATFORM_UNSUPPORTED")
    return Promise.resolve()
  }
  return new Promise((resolve, reject) => {
    let finished = false
    let timedOut = false
    let timer
    let killTimer
    const finish = (reason) => {
      if (finished) return
      finished = true
      if (timer) clearTimeout(timer)
      if (killTimer) clearTimeout(killTimer)
      if (reason) showUpdateFailure(client, reason)
      if (reason) reject(Object.assign(new Error(`AFK startup refused: ${reason}`), { code: reason }))
      else resolve()
    }
    try {
      const detached = process.platform !== "win32"
      const child = spawn(sessionStart, [], { detached, stdio: "ignore", windowsHide: true })
      child.unref()
      child.once("error", (error) => finish(error.code === "ENOENT" ? "UPDATER_UNAVAILABLE" : "UPDATER_FAILED"))
      child.once("exit", (code) => finish(timedOut ? "UPDATER_TIMEOUT" : (code === 0 ? null : "UPDATER_FAILED")))
      timer = setTimeout(() => {
        timedOut = true
        try {
          if (detached && child.pid) process.kill(-child.pid, "SIGTERM")
          else child.kill("SIGTERM")
        } catch {}
        // The reconciler traps TERM and retires its separately tracked child
        // process-group before exiting. KILL is only the bounded last resort;
        // startup never resumes successfully after either timeout path.
        killTimer = setTimeout(() => {
          try {
            if (detached && child.pid) process.kill(-child.pid, "SIGKILL")
            else child.kill("SIGKILL")
          } catch {}
          finish("UPDATER_TIMEOUT")
        }, 2000)
      }, startupTimeout())
    } catch {
      finish("UPDATER_UNAVAILABLE")
    }
  })
}

function field(value) {
  return value === undefined || value === null || value === "" ? { state: "NOT_EVALUATED" } : { state: "AVAILABLE", value }
}
function priorField(previous, name) {
  const value = previous?.[name]
  if (value?.state !== "AVAILABLE") return { state: "NOT_EVALUATED" }
  if (name === "turn_tokens") return Number.isFinite(value.value) ? value : { state: "NOT_EVALUATED" }
  return typeof value.value === "string" && value.value ? value : { state: "NOT_EVALUATED" }
}
function observedField(value, previous, name) {
  return value === undefined || value === null || value === "" ? priorField(previous, name) : field(value)
}
function previousObservation(target, session) {
  try {
    const value = JSON.parse(readFileSync(target, "utf8"))
    return value?.schema === "afk-runtime-observation/1" && value?.harness === "opencode" &&
      session && value?.session?.state === "AVAILABLE" && String(value.session.value) === String(session) ? value : null
  } catch { return null }
}
function publish(event) {
  const info = event?.properties?.info || event?.properties?.part || event?.properties || {}
  const tokens = info.tokens || {}
  const model = info.modelID || info.model?.modelID || info.model?.id || (typeof info.model === "string" ? info.model : null)
  const provider = info.providerID || info.model?.providerID || info.provider?.id || (typeof info.provider === "string" ? info.provider : null)
  const session = info.sessionID || info.session_id || event?.properties?.sessionID || event?.properties?.session?.id ||
    ((event?.type === "session.created" || event?.type === "session.updated") ? info.id : null)
  // Sparse global/plugin events carry no session authority. They must not
  // replace a terminal-scoped observation from the active session.
  if (!session) return
  const cacheDir = sessionCacheDir(session)
  if (!cacheDir) return
  const target = join(cacheDir, "runtime-opencode.json")
  const previous = previousObservation(target, session)
  const turnTokens = info.tokens ? (tokens.input || 0) + (tokens.output || 0) + (tokens.reasoning || 0) : null
  const observation = {
    schema: "afk-runtime-observation/1", harness: "opencode", observed_at: new Date().toISOString(),
    model: observedField(model, previous, "model"),
    provider: observedField(provider, previous, "provider"),
    session: observedField(session, previous, "session"),
    context: { state: "NOT_EVALUATED", used_tokens: null, limit_tokens: null },
    turn_tokens: observedField(turnTokens, previous, "turn_tokens"),
    rate_limits: { five_hour: { state: "NOT_EVALUATED" }, seven_day: { state: "NOT_EVALUATED" } }
  }
  try {
    mkdirSync(cacheDir, { recursive: true, mode: 0o700 })
    const tmp = `${target}.tmp.${process.pid}`
    writeFileSync(tmp, JSON.stringify(observation) + "\n", { mode: 0o600 })
    renameSync(tmp, target)
  } catch {}
  const env = sessionEnvironment(session)
  try { execFile(join(root, "refresh-status-cache.sh"), ["--background"], { timeout: 100, windowsHide: true, env }, () => {}) } catch {}
  try { execFile(join(root, "orca-title.sh"), ["--harness", "opencode"], { timeout: 2500, windowsHide: true, env }, () => {}) } catch {}
  if (session) {
    try {
      execFile(join(root, "pm-session.sh"), ["observe", "--harness", "opencode", "--session", String(session), "--event-type", String(event?.type || "")],
        { timeout: 500, windowsHide: true }, () => {})
    } catch {}
  }
}
function segment(session) {
  try { return execFileSync(join(root, "render-status.sh"), ["--harness", "opencode"], { encoding: "utf8", timeout: 200, env: sessionEnvironment(session) }).trim() }
  catch { return "AFK UNAVAILABLE[STATUS_UNAVAILABLE]" }
}
function eventSession(value) {
  const info = value?.properties?.info || value?.properties?.part || value?.properties || {}
  return value?.sessionID || value?.session_id || value?.session?.id || info.sessionID || info.session_id || info.session?.id ||
    ((value?.type === "session.created" || value?.type === "session.updated") ? info.id : "") || ""
}
function pressureInstruction(session) {
  try {
    return execFileSync(workerContext, ["instruction", "--harness", "opencode", "--session", String(session || "")],
      { encoding: "utf8", timeout: 200, windowsHide: true }).trim()
  } catch { return "" }
}
function publishCompaction(session) {
  try {
    execFile(workerContext, ["compact", "--harness", "opencode", "--session", String(session || "")],
      { timeout: 500, windowsHide: true }, () => {})
  } catch {}
}

export const AfkRuntimePlugin = async ({ client }) => {
  await reconcileAtStartup(client)
  return {
    "experimental.session.compacting": async (input, output) => {
      const session = eventSession(input)
      const instruction = pressureInstruction(session)
      if (instruction && Array.isArray(output?.context)) output.context.push(instruction)
      publishCompaction(session)
    },
    event: async ({ event }) => {
      publish(event)
      if (event?.type === "session.compacted") publishCompaction(eventSession(event))
      if (event?.type === "session.created" || event?.type === "session.idle") {
        try { await client.tui.showToast({ body: { title: "AFK", message: segment(eventSession(event)), variant: "info", duration: 4000 } }) } catch {}
      }
    }
  }
}

export default AfkRuntimePlugin
