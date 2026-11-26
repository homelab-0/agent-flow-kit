//go:build !unix

package main

// refreshBenchmarks is the Unix background refresh; elsewhere the catalog
// is refreshed with afk bench sync.
func refreshBenchmarks(string) {}
