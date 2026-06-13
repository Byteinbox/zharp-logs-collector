package zharpexporter

import (
	"errors"
	"time"
)

const defaultEndpoint = "https://api.zharp.io/api/v1"

// Config holds all configuration for the Zharp exporter.
type Config struct {
	// APIKey is the workspace API key shown in Zharp dashboard → Settings → API Keys.
	APIKey string `mapstructure:"api_key"`

	// Timeout for individual HTTP requests. Defaults to 10s.
	Timeout time.Duration `mapstructure:"timeout"`

	// BatchSize is the maximum log records per HTTP request. Defaults to 500.
	BatchSize int `mapstructure:"batch_size"`
}

func (c *Config) Validate() error {
	if c.APIKey == "" {
		return errors.New("zharpexporter: api_key is required")
	}
	return nil
}
