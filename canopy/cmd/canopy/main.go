// Command canopy runs the APNs relay.
//
// Configuration is entirely environment variables, and every one that matters is
// required rather than defaulted. This service holds the signing keys for every
// install of the app: a missing value should stop the process, not silently
// select a behaviour nobody chose.
package main

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/sadontsev/sprout/canopy/internal/apns"
	"github.com/sadontsev/sprout/canopy/internal/appattest"
	"github.com/sadontsev/sprout/canopy/internal/challenge"
	"github.com/sadontsev/sprout/canopy/internal/fraud"
	"github.com/sadontsev/sprout/canopy/internal/httpapi"
	"github.com/sadontsev/sprout/canopy/internal/keystore"
	"github.com/sadontsev/sprout/canopy/internal/store"
	"github.com/sadontsev/sprout/canopy/internal/tenant"
	"github.com/sadontsev/sprout/canopy/internal/vouch"
)

func main() {
	// Subcommands before anything else: maintenance must not need the full serving configuration
	// (APNs keys, Apple root CA) just to look at the database.
	if len(os.Args) > 1 && os.Args[1] == "prune-tenants" {
		pruneTenants(os.Args[2:])
		return
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	cfg, err := loadConfig()
	if err != nil {
		log.Error("configuration", "err", err)
		os.Exit(1)
	}

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Error("open database", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	sandbox, err := signerFromFile(cfg.SandboxKeyPath, cfg.SandboxKeyID, cfg.TeamID)
	if err != nil {
		log.Error("sandbox signing key", "err", err)
		os.Exit(1)
	}
	production, err := signerFromFile(cfg.ProductionKeyPath, cfg.ProductionKeyID, cfg.TeamID)
	if err != nil {
		log.Error("production signing key", "err", err)
		os.Exit(1)
	}
	client, err := apns.NewClient(cfg.BundleID, sandbox, production)
	if err != nil {
		log.Error("apns client", "err", err)
		os.Exit(1)
	}

	roots, err := loadRoots(cfg.AppleRootPath)
	if err != nil {
		log.Error("apple root ca", "err", err)
		os.Exit(1)
	}

	srv := &httpapi.Server{
		Store:     st,
		Tenants:   &tenant.Service{Store: st, InviteCode: cfg.InviteCode, MaxTenants: cfg.MaxTenants},
		Challenge: &challenge.Service{Store: st},
		Vouch:     &vouch.Service{Store: st, APNs: client},
		APNs:      client,
		Attest: &keystore.Service{
			Store: st,
			Verifier: &appattest.Verifier{
				Roots:            roots,
				AppID:            cfg.TeamID + "." + cfg.BundleID,
				AllowDevelopment: cfg.AllowDevelopmentAttest,
			},
		},
		Now: time.Now,
		Log: log,

		EnrollPerIP:  httpapi.PerMinute(2),
		ClaimsPerIP:  httpapi.PerMinute(60),
		PushPerToken: httpapi.PerMinute(6),
		PerTenant:    httpapi.PerMinute(120),
	}

	go sweep(st, log)

	// The fraud metric is optional. An operator with no DeviceCheck key runs Canopy exactly
	// as before: every other check still holds, and only the hooked-device signal is missing.
	fraudClient, err := fraudClientFrom(cfg)
	switch {
	case errors.Is(err, fraud.ErrNotConfigured):
		log.Info("fraud assessment disabled; set CANOPY_DEVICECHECK_KEY and CANOPY_DEVICECHECK_KEY_ID to enable")
	case err != nil:
		// Configured but unusable. Stopping is right: an operator who supplied a key meant to have
		// this running, and a warning in a log they are not reading is how it stays off for months.
		log.Error("devicecheck key", "err", err)
		os.Exit(1)
	default:
		go fraudSweep(&fraud.Sweeper{
			Keys:   attestKeys{st},
			Client: fraudClient,
			Log:    log,
			AppID:  cfg.TeamID + "." + cfg.BundleID,
		}, log)
	}

	log.Info("canopy listening",
		"addr", cfg.Addr,
		"bundle", cfg.BundleID,
		"development_attest", cfg.AllowDevelopmentAttest)

	server := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}

// sweep drops expired challenges and vouches. Bindings and attest keys are
// deliberately not swept here: they are durable state, restored from backup
// rather than reconstructed by clients.
func sweep(st *store.Store, log *slog.Logger) {
	for {
		time.Sleep(10 * time.Minute)
		now := time.Now()
		if err := st.PurgeExpiredChallenges(now); err != nil {
			log.Error("purge challenges", "err", err)
		}
		if err := st.PurgeExpiredVouches(now); err != nil {
			log.Error("purge vouches", "err", err)
		}
	}
}

// fraudSweep redeems attestation receipts on a slow cadence.
//
// Slow on purpose: Apple states a not-before on every receipt and throttles anything earlier, so a
// tight loop would produce 429s instead of answers. Hourly means a newly attested key is assessed
// within the hour and a steady state costs one round trip per key per day.
func fraudSweep(s *fraud.Sweeper, log *slog.Logger) {
	for {
		res, err := s.Run(context.Background(), time.Now())
		if err != nil {
			log.Error("fraud sweep", "err", err)
		} else if res.Considered > 0 {
			log.Info("fraud sweep",
				"considered", res.Considered, "redeemed", res.Redeemed,
				"deferred", res.Deferred, "suspicious", res.Suspicious)
		}
		time.Sleep(time.Hour)
	}
}

// attestKeys adapts the store to what the sweep needs. The sweep is written against an interface so
// its rules — which keys, how often, what each outcome means — are tested without SQLite.
type attestKeys struct{ st *store.Store }

func (a attestKeys) AttestKeysDueForRedemption(now time.Time, limit int) ([]fraud.KeyRecord, error) {
	rows, err := a.st.AttestKeysDueForRedemption(now, limit)
	if err != nil {
		return nil, err
	}
	out := make([]fraud.KeyRecord, 0, len(rows))
	for _, r := range rows {
		out = append(out, fraud.KeyRecord{KeyID: r.KeyID, Environment: r.Environment, Receipt: r.Receipt})
	}
	return out, nil
}

func (a attestKeys) PutAttestRisk(keyID string, metric int, hasMetric bool, receipt []byte, notBefore, now time.Time) error {
	return a.st.PutAttestRisk(keyID, metric, hasMetric, receipt, notBefore, now)
}

func (a attestKeys) DeferAttestRedemption(keyID string, until, now time.Time) error {
	return a.st.DeferAttestRedemption(keyID, until, now)
}

func fraudClientFrom(cfg config) (*fraud.Client, error) {
	if cfg.DeviceCheckKeyPath == "" || cfg.DeviceCheckKeyID == "" {
		return nil, fraud.ErrNotConfigured
	}
	pemBytes, err := os.ReadFile(cfg.DeviceCheckKeyPath)
	if err != nil {
		return nil, err
	}
	// Host stays empty: each receipt goes to the host matching the environment its own key attested
	// in, which is the only correct choice when one Canopy serves both TestFlight and development.
	// TeamID is the JWT issuer — the same team id everything else here already uses.
	return fraud.NewClient("", cfg.DeviceCheckKeyID, cfg.TeamID, pemBytes)
}

type config struct {
	Addr                   string
	DBPath                 string
	BundleID               string
	TeamID                 string
	SandboxKeyPath         string
	SandboxKeyID           string
	ProductionKeyPath      string
	ProductionKeyID        string
	AppleRootPath          string
	InviteCode             string
	MaxTenants             int
	AllowDevelopmentAttest bool
	// The DeviceCheck key, for the fraud-assessment metric. A different credential from the APNs
	// signing key — that one authorises sending a push, this one authorises reading Apple's
	// per-device risk data — but it comes from the same place in the portal and arrives with the
	// same AuthKey_<id>.p8 filename, so the two are easy to swap by accident. Both optional
	// together; absent means the metric is off.
	//
	// There is no issuer field: this JWT is issued by TeamID, which is already required above. An
	// App Store Connect issuer UUID belongs to a different API and fails here as 401.
	DeviceCheckKeyPath string
	DeviceCheckKeyID   string
}

func loadConfig() (config, error) {
	c := config{
		Addr:                   env("CANOPY_ADDR", "127.0.0.1:8080"),
		DBPath:                 env("CANOPY_DB", "canopy.db"),
		BundleID:               os.Getenv("CANOPY_BUNDLE_ID"),
		TeamID:                 os.Getenv("CANOPY_TEAM_ID"),
		SandboxKeyPath:         os.Getenv("CANOPY_APNS_KEY_SANDBOX"),
		SandboxKeyID:           os.Getenv("CANOPY_APNS_KEY_ID_SANDBOX"),
		ProductionKeyPath:      os.Getenv("CANOPY_APNS_KEY_PRODUCTION"),
		ProductionKeyID:        os.Getenv("CANOPY_APNS_KEY_ID_PRODUCTION"),
		AppleRootPath:          os.Getenv("CANOPY_APPLE_ROOT_CA"),
		InviteCode:             os.Getenv("CANOPY_INVITE_CODE"),
		AllowDevelopmentAttest: os.Getenv("CANOPY_ALLOW_DEVELOPMENT_ATTEST") == "1",
		DeviceCheckKeyPath:     os.Getenv("CANOPY_DEVICECHECK_KEY"),
		DeviceCheckKeyID:       os.Getenv("CANOPY_DEVICECHECK_KEY_ID"),
	}

	required := map[string]string{
		"CANOPY_BUNDLE_ID":              c.BundleID,
		"CANOPY_TEAM_ID":                c.TeamID,
		"CANOPY_APNS_KEY_SANDBOX":       c.SandboxKeyPath,
		"CANOPY_APNS_KEY_ID_SANDBOX":    c.SandboxKeyID,
		"CANOPY_APNS_KEY_PRODUCTION":    c.ProductionKeyPath,
		"CANOPY_APNS_KEY_ID_PRODUCTION": c.ProductionKeyID,
		"CANOPY_APPLE_ROOT_CA":          c.AppleRootPath,
	}
	for name, value := range required {
		if value == "" {
			return config{}, fmt.Errorf("%s is required", name)
		}
	}

	// Both APNs keys are required rather than one-with-a-fallback: modern keys
	// are environment-scoped, so the BadDeviceToken retry has to swap host and
	// key together. A deployment with one key would turn a mislabelled
	// environment into a permanent, silent delivery failure.
	if c.SandboxKeyPath == c.ProductionKeyPath && c.SandboxKeyID == c.ProductionKeyID {
		slog.Warn("the same APNs key is configured for both environments; " +
			"this only works with a legacy universal key")
	}

	if v := os.Getenv("CANOPY_MAX_TENANTS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return config{}, fmt.Errorf("CANOPY_MAX_TENANTS: %w", err)
		}
		c.MaxTenants = n
	}
	return c, nil
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func signerFromFile(path, keyID, teamID string) (*apns.Signer, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return apns.NewSigner(keyID, teamID, pem)
}

func loadRoots(path string) (*x509.CertPool, error) {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		return nil, errors.New("no certificates found; expected the Apple App Attest Root CA in PEM form")
	}
	return pool, nil
}
