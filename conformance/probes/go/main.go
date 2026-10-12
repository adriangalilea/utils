package main

import (
	"errors"

	. "github.com/adriangalilea/go-utils"
)

func main() {
	// Go has no hook before a process exits: what waits to ship leaves here.
	defer FlushLog()
	Log.Info("daemon starting")
	api := Log.Scope("api")
	api.Warn("upstream returned 502", F{"status": 502, "retry": true})
	auth := api.Scope("auth")
	// Shown only when API_AUTH_LOG_LEVEL opens this one scope.
	auth.Debug("token refreshed")
	auth.Error("token expired", F{"err": errors.New("expired")})

	syncRepo()
	_ = deploy()

	// Written out of order: fields come out sorted at every depth.
	Log.Success("ready", F{"took": 1.5, "nested": F{"b": []any{true, nil}, "a": 1}})
	// Below the default level: absence from the output is part of the check.
	Log.Debug("connection pool warm")
	Log.Trace("selector fired")
}

func syncRepo() {
	s := Log.Span("sync", F{"repo": "ui"})
	defer s.End(nil)
	s.Info("cloned", F{"files": 3})
	build(s)
	s.Set(F{"pushed": true})
}

func build(s *Span) {
	c := s.Span("build")
	defer c.End(nil)
	c.Warn("slow step", F{"ms": 1200})
}

func deploy() (err error) {
	s := Log.Span("deploy")
	defer s.End(&err)
	return errors.New("boom")
}
