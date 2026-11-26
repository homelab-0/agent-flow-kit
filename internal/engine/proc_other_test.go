//go:build !unix

package engine

func processAlive(int) bool { return false }
func killPid(int)           {}
