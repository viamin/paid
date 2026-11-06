# frozen_string_literal: true

module ProjectDelegation
  # One reviewable intent checkpoint before downstream delegated work: the
  # grouped material product questions, each with its recommendation,
  # alternatives, consequences, affected scope, and evidence, proposed against
  # one immutable design and acceptance revision. Revisions come from the
  # existing RDR-066/071 records; this model never re-derives them.
  # @spec PROJECT-DELEGATION-002
  class Checkpoint < ApplicationRecord
    self.table_name = "project_delegation_checkpoints"

    STATUSES = %w[open superseded].freeze

    belongs_to :account
    belongs_to :project
    belongs_to :issue, optional: true
    has_many :settlements, class_name: "ProjectDelegation::Settlement", dependent: :restrict_with_error,
      inverse_of: :checkpoint

    validates :design_revision, presence: true, length: { maximum: 200 }
    validates :acceptance_revision, presence: true, length: { maximum: 200 }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validate :groups_present_full_contract
    validate :account_matches_scope

    scope :open, -> { where(status: "open") }

    def supersede!
      update!(status: "superseded")
    end

    def group_keys
      groups.map { |group| group["key"] }
    end

    private

    def groups_present_full_contract
      errors.add(:groups, "must include at least one material question") unless groups.is_a?(Array) && groups.any?
      return unless groups.is_a?(Array)

      keys = groups.filter_map { |group| group["key"] if group.is_a?(Hash) }
      errors.add(:groups, "group keys must be unique") if keys.uniq.length != keys.length
      groups.each { |group| validate_group(group) }
    end

    def validate_group(group)
      return errors.add(:groups, "each group must be an object") unless group.is_a?(Hash)

      prefix = group["key"].presence || "<unnamed>"
      %w[key topic question recommendation consequences].each do |field|
        errors.add(:groups, "#{prefix}: #{field} is required") unless group[field].is_a?(String) && group[field].present?
      end
      validate_alternatives(group, prefix)
      validate_string_list(group, "affected_scope", prefix)
      validate_string_list(group, "evidence", prefix)
    end

    def validate_alternatives(group, prefix)
      alternatives = group["alternatives"]
      return errors.add(:groups, "#{prefix}: alternatives is required") unless alternatives.is_a?(Array)

      errors.add(:groups, "#{prefix}: alternatives must offer at least one option") if alternatives.empty?
      alternatives.each do |alternative|
        labeled = alternative.is_a?(Hash) && alternative["label"].is_a?(String) && alternative["label"].present?
        errors.add(:groups, "#{prefix}: each alternative needs a label") unless labeled
      end
    end

    def validate_string_list(group, field, prefix)
      values = group[field]
      return errors.add(:groups, "#{prefix}: #{field} is required") unless values.is_a?(Array)

      errors.add(:groups, "#{prefix}: #{field} must not be empty") if values.empty?
      return if values.all? { |value| value.is_a?(String) && value.present? }

      errors.add(:groups, "#{prefix}: #{field} entries must be non-blank strings")
    end

    def account_matches_scope
      errors.add(:account, "must match the project") if account && project && account_id != project.account_id
      errors.add(:issue, "must belong to the project") if issue && project && issue.project_id != project.id
    end
  end
end
