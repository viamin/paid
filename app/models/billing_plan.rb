# frozen_string_literal: true

class BillingPlan < ApplicationRecord
  BILLING_MODELS = %w[per_token per_run per_project flat_rate].freeze
  PERIOD_TYPES = %w[daily weekly monthly].freeze

  belongs_to :account
  has_many :billing_periods, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 100 }
  validates :billing_model, presence: true, inclusion: { in: BILLING_MODELS }
  validates :period_type, presence: true, inclusion: { in: PERIOD_TYPES }
  validates :base_rate_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :per_token_rate_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :per_run_rate_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :per_project_rate_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :included_tokens, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :included_runs, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :included_projects, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }

  def flat_rate?
    billing_model == "flat_rate"
  end

  def per_token?
    billing_model == "per_token"
  end

  def per_run?
    billing_model == "per_run"
  end

  def per_project?
    billing_model == "per_project"
  end
end
