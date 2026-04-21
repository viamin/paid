# frozen_string_literal: true

class BillingInvoice < ApplicationRecord
  STATUSES = %w[draft issued paid void].freeze

  belongs_to :account
  belongs_to :billing_period
  has_many :billing_line_items, dependent: :destroy

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :subtotal_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :tax_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :external_id, uniqueness: true, allow_nil: true
  validate :billing_period_belongs_to_account

  scope :draft, -> { where(status: "draft") }
  scope :issued, -> { where(status: "issued") }

  def draft?
    status == "draft"
  end

  def issue!
    update!(status: "issued", issued_at: Time.current)
  end

  def mark_paid!
    update!(status: "paid", paid_at: Time.current)
  end

  def void!
    update!(status: "void")
  end

  def recalculate_totals!
    self.subtotal_cents = billing_line_items.sum(:total_cents)
    self.total_cents = subtotal_cents + tax_cents
    save!
  end

  private

  def billing_period_belongs_to_account
    return if billing_period.blank? || account_id.blank?
    return if billing_period.account_id == account_id

    errors.add(:billing_period, "must belong to the same account")
  end
end
