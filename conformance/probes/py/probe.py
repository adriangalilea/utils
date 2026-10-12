from py_utils import log

log.info("daemon starting")
api = log.scope("api")
api.warn("upstream returned 502", status=502, retry=True)
auth = api.scope("auth")
# Shown only when API_AUTH_LOG_LEVEL opens this one scope.
auth.debug("token refreshed")
auth.error("token expired", err=RuntimeError("expired"))

with log.span("sync", repo="ui") as s:
    s.info("cloned", files=3)
    with s.span("build") as c:
        c.warn("slow step", ms=1200)
    s.set(pushed=True)

try:
    with log.span("deploy"):
        raise RuntimeError("boom")
except RuntimeError:
    pass

# Written out of order: fields come out sorted at every depth.
log.success("ready", took=1.5, nested={"b": [True, None], "a": 1})
# Below the default level: absence from the output is part of the check.
log.debug("connection pool warm")
log.trace("selector fired")
