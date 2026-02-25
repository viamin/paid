# frozen_string_literal: true

class UserSetting < ApplicationRecord
  AGENT_PROVIDERS = %w[claude cursor aider].freeze

  belongs_to :user

  # Polling & Timing
  validates :default_poll_interval_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 60 }
  validates :github_token_cache_ttl_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :token_validation_stale_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  # Agent Execution
  validates :agent_timeout_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 60 }
  validates :default_agent_provider, inclusion: { in: AGENT_PROVIDERS }

  # Container Resources
  validates :container_memory_bytes,
    numericality: { only_integer: true, greater_than_or_equal_to: 512 * 1024 * 1024 } # minimum 512MB
  validates :container_cpu_quota, numericality: { only_integer: true, greater_than_or_equal_to: 100_000 } # minimum 1 CPU
  validates :container_timeout_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 60 }

  # Project Defaults
  validates :default_branch, presence: true

  # Retry & Resilience
  validates :circuit_breaker_failure_threshold, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :circuit_breaker_timeout_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :retry_max_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :retry_base_delay, numericality: { greater_than: 0 }
  validates :retry_max_delay, numericality: { greater_than: 0 }

  # Returns container memory in a human-readable format (GB)
  def container_memory_gb
    container_memory_bytes / (1024.0 * 1024 * 1024)
  end

  # Sets container memory from a human-readable GB value
  def container_memory_gb=(value)
    self.container_memory_bytes = (value.to_f * 1024 * 1024 * 1024).to_i
  end

  # Returns container CPU count (cpu_quota / 100_000)
  def container_cpus
    container_cpu_quota / 100_000
  end

  # Sets container CPU quota from a CPU count
  def container_cpus=(value)
    self.container_cpu_quota = (value.to_i * 100_000)
  end
end
