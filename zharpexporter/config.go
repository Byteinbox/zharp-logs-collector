package zharpexporter

import (
	"errors"
	"time"
)

// Config holds all configuration for the Zharp exporter.
type Config struct {
	// Endpoint is the full base URL of the Zharp backend API.
	// Example: https://api.zharp.io/api/v1
	Endpoint string `mapstructure:"endpoint"`

	// APIKey is the workspace API key (shown in Zharp dashboard → Settings → API Keys).
	APIKey string `mapstructure:"api_key"`

	// Timeout for individual HTTP requests. Defaults to 10s.
	Timeout time.Duration `mapstructure:"timeout"`

	// BatchSize is the maximum log records per HTTP request. Defaults to 500.
	BatchSize int `mapstructure:"batch_size"`
}

func (c *Config) Validate() error {
	if c.Endpoint == "" {
		return errors.New("zharpexporter: endpoint is required")
	}
	if c.APIKey == "" {
		return errors.New("zharpexporter: api_key is required")
	}
	return nil
}
