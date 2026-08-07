# frozen_string_literal: true

source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Bundle and transpile JavaScript [https://github.com/rails/jsbundling-rails]
gem "jsbundling-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Bundle and process CSS [https://github.com/rails/cssbundling-rails]
gem "cssbundling-rails"
gem "chartkick"
# Exception reporting (RDR-039)
gem "exception_notification", "~> 5.0"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Authentication [https://github.com/heartcombo/devise]
gem "devise"

# Authorization [https://github.com/varvet/pundit]
gem "pundit"
gem "avo", "4.0.26"

# Soft-delete for low-volume reference records
gem "discard"

# CSV parsing (bundled gem since Ruby 3.4)
gem "csv"

# GitHub API client [https://github.com/octokit/octokit.rb]
gem "octokit"

gem "faraday-retry"
gem "faraday-http-cache"

# Temporal workflow orchestration [https://temporal.io]
# Defer loading — 139 MB gem with native Rust extensions only needed for
# Temporal client/worker code, not the web process boot path.
gem "temporalio", require: false
gem "opentelemetry-sdk", require: false
gem "opentelemetry-exporter-otlp", require: false

# Docker API client [https://github.com/upserve/docker-api]
# Defer loading — only used by container management services.
gem "docker-api", require: false

# Qdrant vector database client [https://github.com/patterns-ai-core/qdrant-ruby]
# Defer loading — only used by knowledge/vector search services.
gem "qdrant-ruby", require: false

# AWS S3 client [https://github.com/aws/aws-sdk-ruby]
# Defer loading — only used by screenshot storage services.
gem "aws-sdk-s3", require: false

# Unified interface for AI agent CLIs [https://github.com/viamin/agent-harness]
# 0.33.0 ships the opencode-ai bump (>= 1.18.9) that recognizes the
# zai_coding / glm model family (fixes #3045, tracks viamin/agent-harness#316).
gem "agent-harness", "0.33.0"

# Runtime model registry for canonical model metadata, pricing, and capabilities.
gem "ruby_llm", "~> 1.16"

# Code analysis tool for VCS mining (churn/hotspot analysis) [https://github.com/viamin/ruby-maat]
# Defer loading — invoked as CLI binary, not via Ruby API.
gem "ruby-maat", require: false

# Catch unsafe migrations anywhere migrations can run. Phase-1 bridge
# migrations call `safety_assured`, so the gem cannot be limited to
# development/test only.
gem "strong_migrations"

# Runtime feature flags for staged rollouts
gem "flipper"
gem "flipper-active_record"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[windows jruby]

# Use the database-backed adapters for Rails.cache and Action Cable
gem "solid_cache"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"

  # N+1 query detection for Rails requests and specs.
  gem "pg_query", require: false
  gem "prosopite"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Additional RuboCop extensions
  gem "rubocop-rspec", require: false

  # Performance suggestions for Ruby code [https://github.com/fasterer/fasterer]
  gem "fasterer", require: false

  # Testing framework
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "faker"
  gem "shoulda-matchers"
end

group :test do
  gem "simplecov", require: false
  gem "capybara"
  gem "ferrum", path: "vendor/ferrum"
  gem "cuprite"
  gem "fixture_kit"
  # Mutation testing uses the MIT-licensed viamin/mutant fork by default.
  gem "mutant", github: "viamin/mutant", branch: "main", require: false
  gem "mutant-rspec", github: "viamin/mutant", branch: "main", require: false
  gem "rspec-github", "~> 3.0", require: false
  gem "test-prof"
  gem "webmock"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Request-level performance metrics dashboard [https://github.com/igorkasyanchuk/rails_performance]
  gem "rails_performance"

  # Per-request profiler overlay backed by vernier + prosopite [https://github.com/codergeek121/dial]
  gem "dial", "~> 0.6"

  # Developer tools for HTML+ERB templates [https://herb-tools.dev]
  gem "herb", require: false
end

gem "good_job", "~> 4.19"

# Pagination [https://github.com/ddnexus/pagy]
gem "pagy", "~> 43.6"

# PDF text extraction for knowledge imports
gem "pdf-reader"

# Search and filtering [https://github.com/activerecord-hackery/ransack]
gem "ransack"

# Database functions and triggers for schema.rb [https://github.com/teoljungberg/fx]
gem "fx"

# Model change tracking via PostgreSQL triggers [https://github.com/palkan/logidze]
gem "logidze"
