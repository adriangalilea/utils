import { log } from "@adriangalilea/utils/log"

log.info("daemon starting")
const api = log.scope("api")
api.warn("upstream returned 502", { status: 502, retry: true })
const auth = api.scope("auth")
// Shown only when API_AUTH_LOG_LEVEL opens this one scope.
auth.debug("token refreshed")
auth.error("token expired", { err: new Error("expired") })

await log.span("sync", { repo: "ui" }, async (s) => {
	s.info("cloned", { files: 3 })
	await s.span("build", async (c) => {
		c.warn("slow step", { ms: 1200 })
	})
	s.set({ pushed: true })
})

try {
	await log.span("deploy", async () => {
		throw new Error("boom")
	})
} catch {}

// Written out of order: fields come out sorted at every depth.
log.success("ready", { took: 1.5, nested: { b: [true, null], a: 1 } })
// Below the default level: absence from the output is part of the check.
log.debug("connection pool warm")
log.trace("selector fired")
