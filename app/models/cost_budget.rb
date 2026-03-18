# frozen_string_literal: true

class CostBudget < ApplicationRecord
  BUDGET_TYPES = %w[daily monthly per_run].freeze

  belongs_to :project

  validates :budget_type, presence: true, inclusion: { in: BUDGET_TYPES }, uniqueness: { scope: :project_id }
  validates :limit_cents, presence: true, numericality: { greater_than: 0 }
  validates :current_usage_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :alert_threshold_percent, numericality: { greater_than: 0, less_than_or_equal_to: 100 }

  scope :daily, -> { where(budget_type: "daily") }
  scope :monthly, -> { where(budget_type: "monthly") }
  scope :per_run, -> { where(budget_type: "per_run") }
  scope :exceeded, -> { where("current_usage_cents >= limit_cents") }
  scope :active_period, lambda {
    now = Time.current
    daily_start = now.beginning_of_day
    monthly_start = now.beginning_of_month

    where(
      "(budget_type = ? AND (period_started_at IS NULL OR period_started_at >= ?)) OR " \
      "(budget_type = ? AND (period_started_at IS NULL OR period_started_at >= ?)) OR " \
      "(budget_type = ?)",
      "daily", daily_start,
      "monthly", monthly_start,
      "per_run"
    )
  }

  def exceeded?
    current_usage_cents >= limit_cents
  end

  def usage_percent
    return 0 if limit_cents.zero?

    (current_usage_cents.to_f / limit_cents * 100).round(1)
  end

  def alert_threshold_reached?
    usage_percent >= alert_threshold_percent
  end

  def alert_needed?
    alert_threshold_reached? && !alert_recently_sent?
  end

  def remaining_cents
    [ limit_cents - current_usage_cents, 0 ].max
  end

  def record_usage!(cost_cents)
    with_lock do
      rollover_period_if_needed!
      increment!(:current_usage_cents, cost_cents)
    end
  end

  def reset_period!
    update!(current_usage_cents: 0, period_started_at: Time.current, alert_sent_at: nil)
  end

  # Resets per_run budgets so each agent run starts with a fresh allowance.
  # Available for callers that use current_usage_cents for per-run tracking.
  # Note: CostBudgets::Check enforces per_run budgets via
  # agent_run.token_usages.sum(:cost_cents) instead, so it does not call
  # this method. Uses with_lock to avoid racing with concurrent
  # record_usage! calls.
  def reset_for_new_run!
    return unless budget_type == "per_run"

    with_lock do
      update!(current_usage_cents: 0, period_started_at: Time.current, alert_sent_at: nil)
    end
  end

  def mark_alert_sent!
    update!(alert_sent_at: Time.current)
  end

  # Resets usage counters if the current period (daily/monthly) has expired.
  # No-op for per_run budgets. Called by CostBudgets::Check before evaluating
  # the exceeded scope to avoid blocking runs based on stale period data.
  def rollover_if_period_expired!
    with_lock { rollover_period_if_needed! }
  end

  private

  def rollover_period_if_needed!
    return if budget_type == "per_run"

    period_start = case budget_type
    when "daily" then Time.current.beginning_of_day
    when "monthly" then Time.current.beginning_of_month
    end

    if period_started_at.nil? || period_started_at < period_start
      self.current_usage_cents = 0
      self.period_started_at = period_start
      self.alert_sent_at = nil
      save!
    end
  end

  def alert_recently_sent?
    return false if alert_sent_at.nil?

    case budget_type
    when "daily"
      alert_sent_at > 1.day.ago
    when "monthly"
      alert_sent_at > 1.week.ago
    else
      alert_sent_at > 1.hour.ago
    end
  end
end
