# frozen_string_literal: true

class Project < ApplicationRecord
  resourcify

  belongs_to :account
  belongs_to :github_token
  belongs_to :created_by, class_name: "User", optional: true

  has_many :issues, dependent: :destroy
  has_many :agent_runs, dependent: :destroy
  has_many :workflow_states, dependent: :destroy

  validates :name, presence: true
  validates :owner, presence: true
  validates :repo, presence: true
  validates :github_id, presence: true, uniqueness: { scope: :account_id }
  validates :poll_interval_seconds, numericality: { greater_than_or_equal_to: 60 }
  validate :github_token_belongs_to_same_account, if: -> { github_token.present? }
  validate :github_token_is_active, if: -> { github_token.present? && github_token_id_changed? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  def full_name
    "#{owner}/#{repo}"
  end

  def github_url
    "https://github.com/#{full_name}"
  end

  def activate!
    update!(active: true)
  end

  def deactivate!
    update!(active: false)
  end

  def label_for_stage(stage)
    label_mappings[stage.to_s]
  end

  def set_label_for_stage(stage, label)
    self.label_mappings = label_mappings.merge(stage.to_s => label)
  end

  def increment_metrics!(cost_cents:, tokens_used:)
    with_lock do
      update!(
        total_cost_cents: total_cost_cents + cost_cents,
        total_tokens_used: total_tokens_used + tokens_used
      )
    end
  end

  private

  def github_token_belongs_to_same_account
    return if github_token.account_id == account_id

    errors.add(:github_token, "must belong to the same account")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end

  def github_token_is_active
    return if github_token.active?

    errors.add(:github_token, "must be active (not revoked or expired)")
  end
end
