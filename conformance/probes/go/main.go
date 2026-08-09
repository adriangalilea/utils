package main

import . "github.com/adriangalilea/go-utils"

func main() {
	Log.Info("daemon starting")
	api := Log.Scope("api")
	api.Warn("upstream returned 502")
	api.Scope("auth").Error("token expired")
	Log.Success("ready")
	// Below the default level: absence from the output is part of the check.
	Log.Debug("connection pool warm")
	Log.Trace("selector fired")
}
