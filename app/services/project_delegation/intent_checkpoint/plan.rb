# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Builds the reviewable intent checkpoint: groups the known material
    # product questions for a project (and optionally one issue) and records
    # them with their recommendation, alternatives, consequences, affected
    # scope, and evidence against one proposed design/acceptance revision.
    # Question relatedness is decided upstream; this boundary only validates
    # structure and binds revisions, so no semantic judgment happens here.
    # @spec PROJECT-DELEGATION-002
    class Plan
      class Error < StandardError; end
      class InvalidQuestions < Error; end
      class InvalidRevision < Error; end
      class InvalidScope < Error; end
      class AlreadySettled < Error; end

      ALLOWED_FIELDS = %w[
        key topic question recommendation alternatives consequences affected_scope evidence
      ].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(project:, issue: nil, design_revision:, acceptance_revision:, questions:)
        @project = project
        @issue = issue
        @design_revision = design_revision
        @acceptance_revision = acceptance_revision
        @questions = questions
      end

      def call
        ensure_scope!
        ensure_revisions!
        grouped = grouped_questions

        @project.transaction do
          ensure_not_settled!
          checkpoint = open_checkpoint_at_revision
          if checkpoint
            checkpoint.update!(groups: grouped)
          else
            supersede_open_checkpoints
            checkpoint = create_checkpoint(grouped)
          end
          checkpoint
        end
      end

      private

      attr_reader :project, :issue, :design_revision, :acceptance_revision, :questions

      def ensure_scope!
        return if issue.nil? || (issue.project_id == project.id && project.account_id == issue.project.account_id)

        raise InvalidScope, "The work item must belong to the selected project and account."
      end

      def ensure_revisions!
        return if revision?(design_revision) && revision?(acceptance_revision)

        raise InvalidRevision, "Design and acceptance revisions are required to bind a checkpoint."
      end

      def revision?(value)
        value.is_a?(String) && value.strip.present? && value.length <= 200
      end

      def grouped_questions
        raise InvalidQuestions, "At least one material question is required." unless questions.is_a?(Array) && questions.any?

        questions.map { |question| normalize(question) }.sort_by { |group| [ group["topic"], group["key"] ] }
      end

      def normalize(question)
        raise InvalidQuestions, "Each question must be an object." unless question.is_a?(Hash)

        fields = question.stringify_keys
        unknown = fields.keys - ALLOWED_FIELDS
        if unknown.any?
          raise InvalidQuestions, "Question #{fields['key'].presence || '<unnamed>'} has unknown field(s): #{unknown.join(', ')}."
        end

        group = {}
        ALLOWED_FIELDS.each do |field|
          group[field] = normalize_field(field, fields[field], fields["key"])
        end
        group
      end

      def normalize_field(field, value, key)
        prefix = key.presence || "<unnamed>"
        case field
        when "alternatives"
          normalize_alternatives(value, prefix)
        when "affected_scope", "evidence"
          normalize_list(field, value, prefix)
        else
          unless value.is_a?(String) && value.strip.present?
            raise InvalidQuestions, "Question #{prefix} is missing #{field}."
          end

          value.strip
        end
      end

      def normalize_alternatives(value, prefix)
        unless value.is_a?(Array) && value.any?
          raise InvalidQuestions, "Question #{prefix} is missing alternatives."
        end

        value.map do |alternative|
          raise InvalidQuestions, "Question #{prefix} has an alternative without a label." unless alternative.is_a?(Hash)

          label = alternative["label"] || alternative[:label]
          raise InvalidQuestions, "Question #{prefix} has an alternative without a label." unless label.is_a?(String) && label.strip.present?

          normalized = { "label" => label.strip }
          tradeoff = alternative["tradeoff"] || alternative[:tradeoff]
          normalized["tradeoff"] = tradeoff.strip if tradeoff.is_a?(String) && tradeoff.strip.present?
          normalized
        end
      end

      def normalize_list(field, value, prefix)
        unless value.is_a?(Array) && value.any? { |entry| entry.is_a?(String) && entry.strip.present? }
          raise InvalidQuestions, "Question #{prefix} is missing #{field}."
        end

        value.map(&:strip)
      end

      def ensure_not_settled!
        return unless settled_at_revision?

        raise AlreadySettled,
              "Intent was already settled at this revision; route a focused re-decision instead of re-asking."
      end

      def settled_at_revision?
        ProjectDelegation::Settlement.joins(:checkpoint)
          .where(project_delegation_checkpoints: { project_id: project.id, issue_id: issue&.id,
                                                  design_revision: design_revision,
                                                  acceptance_revision: acceptance_revision })
          .where.not(decision: "rejected").exists?
      end

      def open_checkpoint_at_revision
        ProjectDelegation::Checkpoint.open.find_by(
          project: project, issue: issue, design_revision: design_revision, acceptance_revision: acceptance_revision
        )
      end

      def supersede_open_checkpoints
        ProjectDelegation::Checkpoint.open.where(project: project, issue: issue).find_each(&:supersede!)
      end

      def create_checkpoint(groups)
        ProjectDelegation::Checkpoint.create!(
          account: project.account, project: project, issue: issue,
          design_revision: design_revision, acceptance_revision: acceptance_revision,
          status: "open", groups: groups
        )
      end
    end
  end
end
