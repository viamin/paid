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
      [ daily_cap - diagnoses_attempted_today, 0 ].max
    end

    private

    attr_reader :account

    def daily_cap
      configured = account.tenant_setting&.features&.dig("self_heal", "diagnosis_daily_cap")
      value = configured.to_i
      value.positive? ? value : DEFAULT_DAILY_CAP
    end

    def diagnoses_attempted_today
      RemediationDecision
        .where(account: account, diagnosis_attempted_on: Date.current)
        .sum(:diagnosis_attempt_count_on_day)
    end
  end
end
