// Command canopy runs the APNs relay.
//
// Configuration is entirely environment variables, and every one that matters is
// required rather than defaulted. This service holds the signing keys for every
// install of the app: a missing value should stop the process, not silently
// select a behaviour nobody chose.
package main

import (
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/mvks5/canopy/internal/apns"
	"github.com/mvks5/canopy/internal/appattest"
	"github.com/mvks5/canopy/internal/challenge"
	"github.com/mvks5/canopy/internal/httpapi"
	"github.com/mvks5/canopy/internal/keystore"
	"github.com/mvks5/canopy/internal/store"
	"github.com/mvks5/canopy/internal/tenant"
	"github.com/mvks5/canopy/internal/vouch"
)

func main() {
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
