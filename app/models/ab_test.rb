# frozen_string_literal: true

class AbTest < ApplicationRecord
  STATUSES = %w[draft running paused completed cancelled].freeze

  belongs_to :prompt
  belongs_to :account
  belongs_to :winner_variant, class_name: "AbTestVariant", optional: true

  has_many :variants, class_name: "AbTestVariant", dependent: :destroy
  accepts_nested_attributes_for :variants, allow_destroy: true, reject_if: :all_blank

  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :traffic_percentage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :min_sample_size, numericality: { greater_than: 0 }

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :paused, -> { where(status: "paused") }
  scope :completed, -> { where(status: "completed") }
  scope :active_tests, -> { where(status: %w[running paused]) }

  def self.ransackable_attributes(auth_object = nil)
    %w[name status created_at started_at completed_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[prompt account]
  end

  def draft?
    status == "draft"
  end

  def running?
    status == "running"
  end

  def paused?
    status == "paused"
  end

  def completed?
    status == "completed"
  end

  def cancelled?
    status == "cancelled"
  end

  def start!
    raise "Cannot start: test must be in draft or paused state" unless draft? || paused?
    raise "Cannot start: test must have at least 2 variants" if variants.count < 2

    update!(status: "running", started_at: started_at || Time.current)
  end

  def pause!
    raise "Cannot pause: test must be running" unless running?

    update!(status: "paused")
  end

  def complete!(winner: nil)
    raise "Cannot complete: test must be running or paused" unless running? || paused?

    update!(status: "completed", completed_at: Time.current, winner_variant: winner)
  end

  def cancel!
    raise "Cannot cancel: test is already completed" if completed?

    update!(status: "cancelled", completed_at: Time.current)
  end

  def total_samples
    variants.sum(:sample_count)
  end

  def reached_min_sample_size?
    variants.all? { |v| v.sample_count >= min_sample_size }
  end

  def for_prompt?(prompt)
    prompt_id == prompt.id
  end
end
