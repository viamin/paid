# frozen_string_literal: true

module WorkItems
  module ProjectMappings
    # Applies a previewed Linear-project mapping change. Without
    # `confirmed: true` it only returns the preview and writes nothing.
    # Confirmed application never alters a `locked` (overridden) assignment;
    # the affected work item is flagged for review instead.
    #
    # @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-009
    class Apply
      def self.call(...) = new(...).call

      def initialize(account:, provider:, native_project_id:, target_projects:, assignment_mode:,
        native_project_name: nil, default_execution_project: nil, actor: nil, confirmed: false)
        @account = account
        @provider = provider
        @native_project_id = native_project_id
        @native_project_name = native_project_name
        @target_projects = target_projects
        @assignment_mode = assignment_mode
        @default_execution_project = default_execution_project
        @actor = actor
        @confirmed = confirmed
      end

      def call
        enabled_targets = target_projects.select { |project| Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project) }
        raise ArgumentError, "every target project must have unified work items enabled" if enabled_targets != target_projects

        preview = Preview.call(account:, provider:, native_project_id:, target_projects:, assignment_mode:)
        return preview unless confirmed

        mapping = WorkItemProjectMapping.transaction { apply!(preview) }
        Preview::Result.new(mapping:, to_assign: preview.to_assign, to_unassign: preview.to_unassign,
          needs_review: preview.needs_review)
      end

      private

      attr_reader :account, :provider, :native_project_id, :native_project_name, :target_projects,
        :assignment_mode, :default_execution_project, :actor, :confirmed

      def apply!(preview)
        mapping = upsert_mapping
        assign_mapped(mapping, preview.to_assign)
        preview.to_unassign.where(locked: false).destroy_all
        preview.needs_review.find_each(&:flag_for_review!)
        mapping
      end

      def upsert_mapping
        mapping = account.work_item_project_mappings.find_or_initialize_by(provider:, native_project_id:)
        mapping.native_project_name = native_project_name if native_project_name.present?
        mapping.assignment_mode = assignment_mode
        mapping.created_by ||= actor
        mapping.save!
        sync_targets(mapping)
        mapping.update!(default_execution_project: resolved_default_execution_project(mapping))
        mapping
      end

      def sync_targets(mapping)
        mapping.work_item_project_mapping_targets.where.not(project_id: target_projects.map(&:id)).destroy_all
        target_projects.each { |project| mapping.work_item_project_mapping_targets.find_or_create_by!(project:) }
        mapping.association(:projects).reset
      end

      def resolved_default_execution_project(mapping)
        candidate = default_execution_project || mapping.default_execution_project
        return nil unless candidate
        return nil unless target_projects.map(&:id).include?(candidate.id)

        candidate
      end

      def assign_mapped(mapping, work_items)
        work_items.find_each do |work_item|
          target_projects.each { |project| create_mapped_assignment(work_item, project, mapping) }
        end
      end

      def create_mapped_assignment(work_item, project, mapping)
        work_item.work_item_assignments.find_or_create_by!(project:) do |assignment|
          assignment.account = account
          assignment.provenance = "mapping"
          assignment.work_item_project_mapping = mapping
        end
      end
    end
  end
end
