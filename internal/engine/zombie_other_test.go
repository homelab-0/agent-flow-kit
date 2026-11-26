//go:build unix && !linux

package engine

func isZombie(int) bool { return false }
