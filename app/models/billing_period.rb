# frozen_string_literal: true

class BillingPeriod < ApplicationRecord
  PERIOD_TYPES = %w[daily weekly monthly].freeze
  STATUSES = %w[open closed invoiced].freeze

  belongs_to :account
  belongs_to :billing_plan
  has_many :billing_invoices, dependent: :restrict_with_error

  validates :period_type, presence: true, inclusion: { in: PERIOD_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :starts_at, presence: true
  validates :ends_at, presence: true
  validates :total_cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_input_tokens, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_output_tokens, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_runs, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_compute_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :ends_at_after_starts_at

  scope :open, -> { where(status: "open") }
  scope :closed, -> { where(status: "closed") }
  scope :for_date, ->(date) { where("starts_at <= ? AND ends_at > ?", date, date) }

  def open?
    status == "open"
  end

  def closed?
    status == "closed"
  end

  def invoiced?
    status == "invoiced"
  end

  def total_tokens
    total_input_tokens + total_output_tokens
  end

  def close!
    update!(status: "closed")
  end

  private

  def ends_at_after_starts_at
    return if starts_at.blank? || ends_at.blank?

    errors.add(:ends_at, "must be after starts_at") unless ends_at > starts_at
  end
end
