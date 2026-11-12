# frozen_string_literal: true

module WorkItems
  # Unassigned-first browsing with the filters the issue browser needs:
  # provider, native project, assigned project, and review-flag status.
  #
  # @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-009
  class Browse
    def self.call(...) = new(...).call

    def initialize(account:, project: nil, provider: nil, native_project_id: nil, needing_review: nil)
      @account = account
      @project = project
      @provider = provider
      @native_project_id = native_project_id
      @needing_review = needing_review
    end

    def call
      return WorkItem.none unless guard_enabled?

      scope = account.work_items.unassigned_first
      scope = scope.where(provider:) if provider.present?
      scope = scope.for_native_project(native_project_id) if native_project_id.present?
      scope = scope.needing_review if needing_review
      scope = scope.where(id: project.work_items.select(:id)) if project
      scope
    end

    private

    attr_reader :account, :project, :provider, :native_project_id, :needing_review

    def guard_enabled?
      return Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project) if project

      Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled_for_account?(account)
    end
  end
end
