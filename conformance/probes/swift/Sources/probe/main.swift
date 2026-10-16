import Log

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

log.info("daemon starting")
let api = log.scope("api")
api.warn("upstream returned 502", ["status": 502, "retry": true])
let auth = api.scope("auth")
// Shown only when API_AUTH_LOG_LEVEL opens this one scope.
auth.debug("token refreshed")
auth.error("token expired", ["err": ProbeError(description: "expired")])

log.span("sync", ["repo": "ui"]) { s in
    s.info("cloned", ["files": 3])
    s.span("build") { c in
        c.warn("slow step", ["ms": 1200])
    }
    s.set(["pushed": true])
}

_ = try? log.span("deploy") { _ -> Void in
    throw ProbeError(description: "boom")
}

// Written out of order: fields come out sorted at every depth.
log.success("ready", ["took": 1.5, "nested": ["b": [true, nil] as [Bool?], "a": 1] as Fields])
// Below the default level: absence from the output is part of the check.
log.debug("connection pool warm")
log.trace("selector fired")
