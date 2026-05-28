# frozen_string_literal: true

module AgentRunPatterns
  class DailyDiagnosisBudget
    DEFAULT_DAILY_CAP = 20

    def self.remaining_for(...)
      new(...).remaining_for
    end

    def initialize(account:)
      @account = account
    end

    def remaining_for
      [ daily_cap - decisions_created_today, 0 ].max
    end

    private

    attr_reader :account

    def daily_cap
      configured = account.tenant_setting&.features&.dig("self_heal", "diagnosis_daily_cap")
      value = configured.to_i
      value.positive? ? value : DEFAULT_DAILY_CAP
    end

    def decisions_created_today
      RemediationDecision.where(account: account, created_at: Time.current.all_day).count
    end
  end
end
