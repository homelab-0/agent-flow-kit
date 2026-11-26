//go:build !unix

package engine

import "os/exec"

func ownGroup(*exec.Cmd) {}
