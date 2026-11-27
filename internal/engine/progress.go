package engine

import "context"

// Progress is one step of routing, for the live routing screen.
type Progress struct {
	// Kind is "start" (the candidates are known and pool usage is being
	// read), "route" (a CLI's best route is scored) or "skip" (a CLI has
	// no usable route for the task).
	Kind      string
	Task      string
	Guessed   bool
	Prefer    string
	Harnesses []string // on start: every candidate CLI, in order
	Harness   string   // on route and skip
	Route     *Route   // on route
}

type progressKey struct{}

// WithProgress returns a context whose routing steps are passed to fn.
func WithProgress(ctx context.Context, fn func(Progress)) context.Context {
	return context.WithValue(ctx, progressKey{}, fn)
}

// ReportProgress passes p to the context's progress function, if any.
func ReportProgress(ctx context.Context, p Progress) {
	if fn, ok := ctx.Value(progressKey{}).(func(Progress)); ok && fn != nil {
		fn(p)
	}
}
