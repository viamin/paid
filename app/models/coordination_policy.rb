# frozen_string_literal: true

class CoordinationPolicy < ApplicationRecord
  POLICY_TYPES = %w[decomposition recovery escalation lifecycle_state].freeze
  STATUSES = %w[draft active archived].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :current_version, class_name: "CoordinationPolicyVersion", optional: true

  has_many :coordination_policy_versions, dependent: :destroy

  validates :policy_type, presence: true, inclusion: { in: POLICY_TYPES }
  validates :policy_key, presence: true, length: { maximum: 100 }
  validates :policy_key, uniqueness: { scope: [ :account_id, :policy_type ], conditions: -> { where(project_id: nil) } }, if: :account_level?
  validates :policy_key, uniqueness: { scope: [ :account_id, :project_id, :policy_type ] }, if: :project_level?
  validates :name, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :current_version_belongs_to_policy
  validate :project_belongs_to_account
  validate :context_selector_is_object
  validate :metadata_is_object

  scope :active, -> { where(status: "active") }
  scope :by_type, ->(policy_type) { where(policy_type:) }
  scope :for_account, ->(account) { where(account:) }

  def account_level?
    project_id.nil?
  end

  def project_level?
    project_id.present?
  end

  def self.resolve_for(account:, policy_type:, project: nil)
    candidates = active.for_account(account).by_type(policy_type)
    return candidates.where(project_id: nil).order(:id).first unless project

    candidates
      .where(project_id: [ project.id, nil ])
      .order(Arel.sql("CASE WHEN project_id = #{project.id} THEN 0 ELSE 1 END"), :id)
      .first
  end

  def activate_version!(policy_version)
    raise ActiveRecord::RecordInvalid, self unless policy_version.coordination_policy_id == id

    transaction do
      now = Time.current
      coordination_policy_versions.active.where.not(id: policy_version.id).find_each do |version|
        version.update!(status: "superseded", retired_at: now)
      end

      policy_version.update!(status: "active", activated_at: now, retired_at: nil)
      update!(current_version: policy_version, status: "active")
    end
  end

  private

  def current_version_belongs_to_policy
    return if current_version.nil?
    return if current_version.coordination_policy_id == id

    errors.add(:current_version, "must belong to this coordination policy")
  end

  def project_belongs_to_account
    return if project.nil?
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def context_selector_is_object
    validate_json_object(:context_selector)
  end

  def metadata_is_object
    validate_json_object(:metadata)
  end

  def validate_json_object(attribute)
    return if public_send(attribute).is_a?(Hash)

    errors.add(attribute, "must be a JSON object")
  end
end
