# frozen_string_literal: true

module Billing
  class CalculateCharges
    attr_reader :billing_period, :billing_plan

    def initialize(billing_period:)
      @billing_period = billing_period
      @billing_plan = billing_period.billing_plan
    end

    def self.call(...)
      new(...).call
    end

    def call
      line_items = []
      line_items << base_rate_item if billing_plan.base_rate_cents > 0
      line_items.concat(usage_items)
      line_items
    end

    private

    def base_rate_item
      {
        description: "#{billing_plan.name} - Base rate (#{billing_plan.period_type})",
        line_item_type: "base_rate",
        quantity: 1,
        unit_price_cents: billing_plan.base_rate_cents,
        total_cents: billing_plan.base_rate_cents
      }
    end

    def usage_items
      case billing_plan.billing_model
      when "flat_rate" then []
      when "per_token" then token_usage_items
      when "per_run" then run_usage_items
      when "per_project" then project_usage_items
      else []
      end
    end

    def token_usage_items
      items = []
      total_tokens = billing_period.total_input_tokens + billing_period.total_output_tokens
      included = billing_plan.included_tokens
      billable_tokens = [ total_tokens - included, 0 ].max

      if included > 0 && total_tokens > 0
        included_used = [ total_tokens, included ].min
        items << {
          description: "Included tokens (#{format_tokens(included_used)} of #{format_tokens(included)})",
          line_item_type: "token_usage",
          quantity: included_used,
          unit_price_cents: 0,
          total_cents: 0
        }
      end

      if billable_tokens > 0
        items << overage_token_item(billable_tokens)
      end

      items
    end

    def overage_token_item(billable_tokens)
      per_thousand_rate_cents = billing_plan.per_token_rate_cents * 1000

      {
        description: "Overage tokens (#{format_tokens(billable_tokens)} @ #{format_decimal(per_thousand_rate_cents)}¢/1K)",
        line_item_type: "overage_tokens",
        quantity: billable_tokens / 1000.0,
        unit_price_cents: per_thousand_rate_cents.round,
        total_cents: (billable_tokens * billing_plan.per_token_rate_cents).round
      }
    end

    def run_usage_items
      items = []
      total_runs = billing_period.total_runs
      included = billing_plan.included_runs
      billable_runs = [ total_runs - included, 0 ].max

      if included > 0 && total_runs > 0
        included_used = [ total_runs, included ].min
        items << {
          description: "Included runs (#{included_used} of #{included})",
          line_item_type: "run_usage",
          quantity: included_used,
          unit_price_cents: 0,
          total_cents: 0
        }
      end

      if billable_runs > 0
        items << {
          description: "Overage runs (#{billable_runs})",
          line_item_type: "overage_runs",
          quantity: billable_runs,
          unit_price_cents: billing_plan.per_run_rate_cents,
          total_cents: billable_runs * billing_plan.per_run_rate_cents
        }
      end

      items
    end

    def project_usage_items
      items = []
      project_count = billing_period.metadata["project_count"].to_i
      included = billing_plan.included_projects
      billable_projects = [ project_count - included, 0 ].max

      if included > 0 && project_count > 0
        included_used = [ project_count, included ].min
        items << {
          description: "Included projects (#{included_used} of #{included})",
          line_item_type: "project_usage",
          quantity: included_used,
          unit_price_cents: 0,
          total_cents: 0
        }
      end

      if billable_projects > 0
        items << {
          description: "Additional projects (#{billable_projects})",
          line_item_type: "project_usage",
          quantity: billable_projects,
          unit_price_cents: billing_plan.per_project_rate_cents,
          total_cents: billable_projects * billing_plan.per_project_rate_cents
        }
      end

      items
    end

    def format_tokens(count)
      if count >= 1_000_000
        "#{(count / 1_000_000.0).round(1)}M"
      elsif count >= 1_000
        "#{(count / 1_000.0).round(1)}K"
      else
        count.to_s
      end
    end

    def format_decimal(value)
      formatted = BigDecimal(value.to_s).to_s("F").sub(/\.?0+\z/, "")
      formatted.presence || "0"
    end
  end
end
