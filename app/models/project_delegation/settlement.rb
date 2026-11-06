# frozen_string_literal: true

module ProjectDelegation
  # The immutable record of one human settlement: the decision (settled,
  # rejected, or amended) and per-group answers, bound to the design and
  # acceptance revision current when the human decided. Settlements are
  # append-only history — a later settlement never rewrites an earlier one.
  # @spec PROJECT-DELEGATION-002
  class Settlement < ApplicationRecord
    self.table_name = "project_delegation_settlements"

    DECISIONS = %w[settled rejected amended].freeze

    belongs_to :checkpoint, class_name: "ProjectDelegation::Checkpoint", inverse_of: :settlements
    belongs_to :account
    belongs_to :project
    belongs_to :settled_by, class_name: "User", inverse_of: :project_delegation_settlements

    validates :decision, presence: true, inclusion: { in: DECISIONS }
    validates :design_revision, presence: true, length: { maximum: 200 }
    validates :acceptance_revision, presence: true, length: { maximum: 200 }
    validate :answers_reference_asked_groups
    validate :account_matches_scope

    # Settlements are immutable once persisted; a changed intent appends a new
    # settlement rather than rewriting history.
    def readonly?
      persisted?
    end

    def answer_for(group_key)
      answers.find { |answer| answer["key"] == group_key }
    end

    private

    def answers_reference_asked_groups
      errors.add(:answers, "must be a list") unless answers.is_a?(Array)

      keys = answers.filter_map { |answer| answer["key"] if answer.is_a?(Hash) }
      duplicates = keys.tally.select { |_, count| count > 1 }.keys
      errors.add(:answers, "answers must be unique per group: #{duplicates.join(', ')}") if duplicates.any?

      asked = checkpoint.group_keys
      answers.each do |answer|
        next unless answer.is_a?(Hash)

        key = answer["key"]
        errors.add(:answers, "#{key.presence || "<unnamed>"} was not asked") unless key.in?(asked)
        errors.add(:answers, "#{key} needs a choice") unless answer["choice"].is_a?(String) && answer["choice"].present?
      end

      ensure_full_coverage(asked)
    end

    def ensure_full_coverage(asked)
      return unless decision == "settled"

      missing = asked - answers.filter_map { |answer| answer["key"] if answer.is_a?(Hash) }
      errors.add(:answers, "every group must be answered: #{missing.join(', ')}") if missing.any?
    end

    def account_matches_scope
      errors.add(:account, "must match the project") if account && project && account_id != project.account_id
      errors.add(:project, "must match the checkpoint") if checkpoint && project && project_id != checkpoint.project_id
      if checkpoint && account && checkpoint.account_id != account_id
        errors.add(:checkpoint, "must belong to the account")
      end
      errors.add(:settled_by, "must belong to the account") if settled_by && account && settled_by.account_id != account_id
    end
  end
end
