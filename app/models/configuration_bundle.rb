# frozen_string_literal: true

class ConfigurationBundle < ApplicationRecord
  STATUSES = %w[draft active retired].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :prompt_version, optional: true
  belongs_to :llm_model, optional: true

  has_many :bundle_outcomes, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 }
  validate :version_unique_for_scope
  validates :strategy, length: { maximum: 100 }, allow_nil: true
  validates :fingerprint, length: { maximum: 64 }, uniqueness: { scope: :account_id }, allow_nil: true
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }
  validate :prompt_version_matches_scope, if: -> { prompt_version.present? }

  scope :draft, -> { where(status: "draft") }
  scope :active, -> { where(status: "active") }
  scope :retired, -> { where(status: "retired") }

  def activate!
    with_lock do
      reload
      raise_invalid_transition!("activate", "draft") unless draft?

      update!(status: "active", activated_at: Time.current)
    end
  end

  def retire!
    with_lock do
      reload
      raise_invalid_transition!("retire", "active") unless active?

      update!(status: "retired", retired_at: Time.current)
    end
  end

  def draft?
    status == "draft"
  end

  def active?
    status == "active"
  end

  def retired?
    status == "retired"
  end

  def avg_quality_score
    bundle_outcomes.average(:quality_score)
  end

  def success_rate
    total, successful = bundle_outcomes.pick(Arel.sql("COUNT(*), COUNT(*) FILTER (WHERE success)"))
    return nil if total.nil? || total.zero?

    successful.to_f / total
  end

  private

  def raise_invalid_transition!(action, required_status)
    errors.add(:base, "cannot #{action} a bundle that is #{status} (must be #{required_status})")
    raise ActiveRecord::RecordInvalid, self
  end

  def version_unique_for_scope
    return if version.blank? || account_id.blank?

    scope = self.class.where(account_id: account_id, version: version)
    scope = project_id.nil? ? scope.where(project_id: nil) : scope.where(project_id: project_id)
    scope = scope.where.not(id: id) if persisted?

    errors.add(:version, :taken) if scope.exists?
  end

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def prompt_version_matches_scope
    prompt = prompt_version.prompt
    return if prompt.global?
    return if prompt.account_level? && prompt.account_id == account_id
    return if prompt.project_level? && prompt.account_id == account_id && prompt.project_id == project_id

    errors.add(:prompt_version, "must match the bundle account/project scope")
  end
end
