package main

import (
	"fmt"
	"io"
	"runtime"
	"runtime/debug"
)

// Set at release time by GoReleaser through -ldflags -X.
var (
	version = ""
	commit  = ""
	date    = ""
)

// buildVersion returns the version, commit and build date. A release
// build has them from -ldflags; a `go install ...@v0.1.0` build has the
// module version and VCS stamp in its build info; anything else is "dev".
func buildVersion(info *debug.BuildInfo, ok bool) (v, c, d string) {
	v, c, d = version, commit, date
	if ok && info != nil {
		if v == "" && info.Main.Version != "" && info.Main.Version != "(devel)" {
			v = info.Main.Version
		}
		for _, s := range info.Settings {
			switch s.Key {
			case "vcs.revision":
				if c == "" {
					c = s.Value
				}
			case "vcs.time":
				if d == "" {
					d = s.Value
				}
			}
		}
	}
	if v == "" {
		v = "dev"
	}
	if len(c) > 12 {
		c = c[:12]
	}
	return v, c, d
}

func versionLine() string {
	info, ok := debug.ReadBuildInfo()
	v, c, d := buildVersion(info, ok)
	line := "afk " + v
	if c != "" {
		line += " (" + c
		if d != "" {
			line += ", " + d
		}
		line += ")"
	}
	return line + " " + runtime.GOOS + "/" + runtime.GOARCH
}

func versionCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) > 0 {
		fmt.Fprintf(stderr, "afk version takes no arguments\n")
		return 2
	}
	fmt.Fprintln(stdout, versionLine())
	return 0
}
