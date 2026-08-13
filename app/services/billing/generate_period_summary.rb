# frozen_string_literal: true

module Billing
  class GeneratePeriodSummary
    attr_reader :billing_period

    def initialize(billing_period:)
      @billing_period = billing_period
    end

    def self.call(...)
      new(...).call
    end

    def call
      usage = AggregateTenantUsage.call(
        account: billing_period.account,
        starts_at: billing_period.starts_at,
        ends_at: billing_period.ends_at
      )

      billing_period.update!(
        total_cost_cents: usage.dig(:token_usage, :total_cost_cents),
        total_input_tokens: usage.dig(:token_usage, :total_input_tokens),
        total_output_tokens: usage.dig(:token_usage, :total_output_tokens),
        total_runs: usage.dig(:run_usage, :total_runs),
        total_compute_seconds: usage.dig(:compute_usage, :total_compute_seconds),
        metadata: billing_period.metadata.merge(
          "cost_by_project" => usage[:cost_by_project],
          "cost_by_model" => usage.dig(:token_usage, :by_model),
          "project_count" => usage[:project_count],
          "generated_at" => Time.current.iso8601
        )
      )

      billing_period
    end
  end
end
