# frozen_string_literal: true

module WorkItems
  # Posts a Paid-authored comment to a unified work item's provider ticket as
  # the configured API-key user. Posting is permitted unless the acting
  # project is in quiet mode; imported comments are never reposted through
  # this service, which only delivers Paid-authored text.
  #
  # @spec UNIFIED-WORK-ITEMS-005 UNIFIED-WORK-ITEMS-009
  class PostComment
    STATUSES = %i[posted suppressed unsupported rollout_disabled failed].freeze

    def self.call(...) = new(...).call

    def initialize(work_item:, project:, body:)
      @work_item = work_item
      @project = project
      @body = body
    end

    def call
      return :rollout_disabled unless guard_enabled?
      return :suppressed if project.quiet_mode?
      return :unsupported if adapter.blank?
      return :unsupported if body.blank?

      adapter.add_comment(external_id: work_item.external_id, body: body)
      :posted
    rescue IssueTrackers::Adapters::Linear::Error => error
      # @spec UNIFIED-WORK-ITEMS-002
      Rails.logger.warn(
        message: "work_items.post_comment_failed",
        work_item_id: work_item.id,
        provider: work_item.provider,
        error_class: error.class.name,
        error: error.message
      )
      :failed
    end

    private

    attr_reader :work_item, :project, :body

    def guard_enabled?
      Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project)
    end

    def adapter
      return nil unless work_item.tracker_configuration&.enabled?

      work_item.tracker_configuration.adapter
    rescue ArgumentError
      nil
    end
  end
end
