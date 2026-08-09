from py_utils import log

log.info("daemon starting")
api = log.scope("api")
api.warn("upstream returned 502")
api.scope("auth").error("token expired")
log.success("ready")
# Below the default level: absence from the output is part of the check.
log.debug("connection pool warm")
log.trace("selector fired")
