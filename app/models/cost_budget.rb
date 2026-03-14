# frozen_string_literal: true

class CostBudget < ApplicationRecord
  BUDGET_TYPES = %w[daily monthly per_run].freeze
  DEFAULT_ALERT_THRESHOLD = 80

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

  def mark_alert_sent!
    update!(alert_sent_at: Time.current)
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
