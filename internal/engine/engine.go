// Package engine holds the routing contract AFK's parts share: the route,
// the routing decision (explain), the launch plan and the pool usage, as
// JSON with a schema. Every payload carries a schema, and a version this
// package does not know is refused rather than guessed at.
package engine

import (
	"encoding/json"
	"fmt"
)

// Schemas this package reads and writes.
const (
	SchemaExplain    = "afk-route-explain/2"
	SchemaLaunchPlan = "afk-launch-plan/1"
	SchemaPools      = "afk-router-pools/5"
)

// RouteFlags are the routing options the user gave.
type RouteFlags struct {
	Task, Prefer, Harness, Model, Effort, Repo string
	// Perm is the permission mode from --mode or --yolo ("" when not
	// given).
	Perm string
	// NoPlan keeps the route off every CLI's own sign-in: only a gateway,
	// a local engine or a free pool may answer. afk serve sets it while
	// serve.plan_runs is off.
	NoPlan bool
}

// PlanError is a route AFK will not start, with its reason.
type PlanError struct{ Reason string }

func (e *PlanError) Error() string { return e.Reason }

// SchemaError is a payload whose schema this package does not know.
type SchemaError struct{ Want, Got string }

func (e *SchemaError) Error() string {
	if e.Got == "" {
		return fmt.Sprintf("the payload has no schema (expected %s)", e.Want)
	}
	return fmt.Sprintf("the payload is %s, expected %s", e.Got, e.Want)
}

func checkSchema(b []byte, want string) error {
	var head struct {
		Schema string `json:"schema"`
	}
	if err := json.Unmarshal(b, &head); err != nil {
		return fmt.Errorf("not JSON: %w", err)
	}
	if head.Schema != want {
		return &SchemaError{Want: want, Got: head.Schema}
	}
	return nil
}
