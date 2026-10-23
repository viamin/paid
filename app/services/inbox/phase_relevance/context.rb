# frozen_string_literal: true

module Inbox
  class PhaseRelevance
    # Queue-scoped policy evidence. It resolves rollout, work chains, grants,
    # and unfinished manual actions in bounded queries before entries are
    # classified, avoiding one policy query set per Inbox row.
    class Context
      def initialize(entries:, governed_project_ids: nil)
        @entries = entries
        @governed_project_ids = governed_project_ids&.to_set
      end

      def governed?(ownership)
        ownership.project && governed_project_ids.include?(ownership.project.id)
      end

      def grant_covers?(entry, ownership)
        grants_by_work_item.fetch([ ownership.project.id, root_id_for(entry) ], [])
          .any? { |grant| grant.covers_phase?(ownership.responsible_phase) }
      end

      def outstanding_manual_action?(entry, ownership)
        manual_action_keys.include?([ ownership.project.id, root_id_for(entry) ])
      end

      def automatic_authorized?(entry, project:, phase:)
        return true unless governed_project_ids.include?(project.id)
        return true if Automation::PhaseSettings.phase_enabled?(project, phase)

        grants_by_work_item.fetch([ project.id, root_id_for(entry) ], [])
          .any? { |grant| grant.covers_phase?(phase) }
      end

      private

      attr_reader :entries

      def governed_project_ids
        @governed_project_ids ||= Automation::RolloutGuard.enabled_project_ids(project_ids).to_set
      end

      def project_ids
        entries.filter_map { |entry| entry.project&.id }.uniq
      end

      def chain_ids(entry)
        chain_ids_by_entry.fetch(entry.id, [])
      end

      def root_id_for(entry)
        issue = entry.issue || (entry.record if entry.record.is_a?(Issue))
        return unless issue

        issue.is_pull_request? && issue.parent_issue_id ? issue.parent_issue_id : issue.id
      end

      def chain_ids_by_entry
        @chain_ids_by_entry ||= issue_entries.to_h do |entry|
          issue = entry.issue || entry.record
          root_id = issue.is_pull_request? && issue.parent_issue_id ? issue.parent_issue_id : issue.id
          [ entry.id, ([ issue.id ] + pull_request_ids_by_root.fetch(root_id, []) + [ root_id ]).uniq ]
        end
      end

      def issue_entries
        @issue_entries ||= entries.select do |entry|
          entry.issue || entry.record.is_a?(Issue)
        end
      end

      def root_ids
        issue_entries.map do |entry|
          issue = entry.issue || entry.record
          issue.is_pull_request? && issue.parent_issue_id ? issue.parent_issue_id : issue.id
        end.uniq
      end

      def pull_request_ids_by_root
        @pull_request_ids_by_root ||= begin
          return {} if root_ids.empty?

          Issue.where(parent_issue_id: root_ids, is_pull_request: true).pluck(:parent_issue_id, :id)
            .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        end
      end

      def all_chain_ids
        chain_ids_by_entry.values.flatten.uniq
      end

      def grants_by_work_item
        @grants_by_work_item ||= begin
          return {} if all_chain_ids.empty?

          WorkItemContinuationGrant.active.where(project_id: project_ids, issue_id: all_chain_ids)
            .group_by { |grant| [ grant.project_id, root_by_issue_id.fetch(grant.issue_id) ] }
        end
      end

      def manual_action_keys
        @manual_action_keys ||= begin
          return Set.new if all_chain_ids.empty?

          AgentRun.where(project_id: project_ids, issue_id: all_chain_ids, trigger_type: "manual")
            .where(status: AgentRun::UNFINISHED_STATUSES).pluck(:project_id, :issue_id)
            .map { |project_id, issue_id| [ project_id, root_by_issue_id.fetch(issue_id) ] }.to_set
        end
      end

      def root_by_issue_id
        @root_by_issue_id ||= issue_entries.each_with_object({}) do |entry, roots|
          root_id = root_id_for(entry)
          chain_ids(entry).each { |issue_id| roots[issue_id] = root_id }
        end
      end
    end
  end
end
