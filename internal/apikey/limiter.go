package apikey

import (
	"strconv"
	"sync"
	"time"
)

// Limiter counts the calls each key makes and holds them to the key's
// limits. It lives in the afk serve process; a key is known by its name,
// so rotating a key does not reset its counts.
type Limiter struct {
	Now func() time.Time

	mu     sync.Mutex
	hits   map[string][]time.Time // calls let through in the last 24 hours, oldest first
	active map[string]int
}

// Denied is a call a limit turned away.
type Denied struct {
	// Limit is per_minute, per_day or concurrent.
	Limit string
	// Max is the limit's value.
	Max int
	// RetryAfter is how long until the limit lets a call through again
	// (a guess of a few seconds for concurrent, which ends when a run
	// does).
	RetryAfter time.Duration
}

func (d *Denied) Error() string {
	switch d.Limit {
	case "per_minute":
		return "this key's limit of " + itoa(d.Max) + " requests a minute is used up"
	case "per_day":
		return "this key's limit of " + itoa(d.Max) + " requests a day is used up"
	}
	return "this key already has " + itoa(d.Max) + " " + plural(d.Max, "run", "runs") + " going, its limit"
}

func (l *Limiter) now() time.Time {
	if l.Now != nil {
		return l.Now()
	}
	return time.Now()
}

// Acquire lets one call through the key's limits, or says which limit
// turned it away. release must be called when the call's run has ended.
func (l *Limiter) Acquire(k Key) (release func(), denied *Denied) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	hits := l.trim(k.Name, now)
	lim := k.Limits
	if lim.Concurrent > 0 && l.active[k.Name] >= lim.Concurrent {
		return nil, &Denied{Limit: "concurrent", Max: lim.Concurrent, RetryAfter: 5 * time.Second}
	}
	if lim.PerDay > 0 && len(hits) >= lim.PerDay {
		return nil, &Denied{Limit: "per_day", Max: lim.PerDay, RetryAfter: until(hits[len(hits)-lim.PerDay], 24*time.Hour, now)}
	}
	if lim.PerMinute > 0 {
		cut := now.Add(-time.Minute)
		n := 0
		for i := len(hits) - 1; i >= 0 && hits[i].After(cut); i-- {
			n++
		}
		if n >= lim.PerMinute {
			// The call that frees a slot is the PerMinute-th newest.
			free := hits[len(hits)-lim.PerMinute]
			return nil, &Denied{Limit: "per_minute", Max: lim.PerMinute, RetryAfter: until(free, time.Minute, now)}
		}
	}
	if l.hits == nil {
		l.hits, l.active = map[string][]time.Time{}, map[string]int{}
	}
	l.hits[k.Name] = append(hits, now)
	l.active[k.Name]++
	name := k.Name
	var once sync.Once
	return func() {
		once.Do(func() {
			l.mu.Lock()
			if l.active[name] > 0 {
				l.active[name]--
			}
			l.mu.Unlock()
		})
	}, nil
}

// Seed records calls made before this process started (from the run
// records), so a restart does not hand a key a fresh day.
func (l *Limiter) Seed(name string, at []time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.hits == nil {
		l.hits, l.active = map[string][]time.Time{}, map[string]int{}
	}
	all := append(l.hits[name], at...)
	sortTimes(all)
	l.hits[name] = all
	l.trim(name, l.now())
}

// Counts is how many calls the key made in the last minute and the last
// 24 hours, and how many of its runs are going now.
func (l *Limiter) Counts(name string) (minute, day, active int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	hits := l.trim(name, now)
	cut := now.Add(-time.Minute)
	for i := len(hits) - 1; i >= 0 && hits[i].After(cut); i-- {
		minute++
	}
	return minute, len(hits), l.active[name]
}

// trim drops the key's calls older than 24 hours and returns the rest.
func (l *Limiter) trim(name string, now time.Time) []time.Time {
	hits := l.hits[name]
	cut := now.Add(-24 * time.Hour)
	i := 0
	for i < len(hits) && !hits[i].After(cut) {
		i++
	}
	if i > 0 {
		hits = append([]time.Time(nil), hits[i:]...)
		l.hits[name] = hits
	}
	return hits
}

func until(t time.Time, window time.Duration, now time.Time) time.Duration {
	d := t.Add(window).Sub(now)
	if d < time.Second {
		d = time.Second
	}
	return d.Round(time.Second)
}

func sortTimes(ts []time.Time) {
	for i := 1; i < len(ts); i++ {
		for j := i; j > 0 && ts[j].Before(ts[j-1]); j-- {
			ts[j], ts[j-1] = ts[j-1], ts[j]
		}
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
