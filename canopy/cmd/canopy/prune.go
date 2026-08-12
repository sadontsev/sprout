package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/store"
)

// pruneTenants removes tenants that enrolled and never bound anything.
//
// This exists because the job was once done by hand, against the live database, with a filter
// typed in the moment: "no bindings AND created in the last hour". That is backwards. A tenant
// with no bindings that enrolled an hour ago is most likely a real deployment mid-setup, whose
// user has not opened the app yet — and deleting it left someone holding credentials Canopy no
// longer recognised, with no way for them to tell why push had stopped.
//
// So the shape of this command is the lesson:
//
//   - DRY RUN BY DEFAULT. Deleting requires --apply. A maintenance command whose default is
//     destructive will eventually be run by someone who only meant to look.
//   - The age bound is a MINIMUM, not a maximum. Old-and-empty is junk; new-and-empty is a user.
//   - Never a tenant with bindings, enforced in the SQL rather than here, because a check the
//     caller performs is a check a future caller can forget.
func pruneTenants(args []string) {
	fs := flag.NewFlagSet("prune-tenants", flag.ExitOnError)
	dbPath := fs.String("db", env("CANOPY_DB", "canopy.db"), "path to the database")
	olderThan := fs.Duration("older-than", 30*24*time.Hour,
		"only consider tenants enrolled at least this long ago")
	apply := fs.Bool("apply", false, "actually delete; without it this only reports")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `canopy prune-tenants — remove tenants that never bound a token

Reports by default and deletes nothing. Add --apply to delete.

A tenant holding ANY binding is never a candidate, released or expired. The age bound is a
minimum: an empty tenant that enrolled recently is far more likely to be someone still setting
up than junk, and deleting it costs them their push with no way to discover why.

`)
		fs.PrintDefaults()
	}
	_ = fs.Parse(args)

	st, err := store.Open(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open %s: %v\n", *dbPath, err)
		os.Exit(1)
	}
	defer st.Close()

	cutoff := time.Now().Add(-*olderThan)
	candidates, err := st.TenantsWithoutBindings(cutoff)
	if err != nil {
		fmt.Fprintf(os.Stderr, "query: %v\n", err)
		os.Exit(1)
	}

	total, err := st.CountTenants()
	if err != nil {
		fmt.Fprintf(os.Stderr, "count: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("%d tenants total; %d have no bindings and enrolled before %s\n",
		total, len(candidates), cutoff.UTC().Format("2006-01-02 15:04Z"))
	if len(candidates) == 0 {
		return
	}
	for _, c := range candidates {
		fmt.Printf("  %s  enrolled %s  last seen %s\n",
			c.ID, c.CreatedAt.Format("2006-01-02 15:04Z"), c.LastSeen.Format("2006-01-02 15:04Z"))
	}

	if !*apply {
		fmt.Printf("\nnothing deleted. Re-run with --apply to remove these %d.\n", len(candidates))
		return
	}

	removed := 0
	for _, c := range candidates {
		ok, err := st.DeleteTenant(c.ID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "delete %s: %v\n", c.ID, err)
			continue
		}
		if ok {
			removed++
		} else {
			// It bound something between the query and now. The SQL refused, which is the point.
			fmt.Printf("  skipped %s — it holds a binding now\n", c.ID)
		}
	}
	fmt.Printf("\nremoved %d tenant(s).\n", removed)
}
