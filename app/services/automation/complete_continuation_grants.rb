# frozen_string_literal: true

module Automation
  # Completes grants when a pull request reaches the terminal state for the
  # grant's selected endpoint. Completion is durable, so a later restart or
  # reopen cannot restore the exception.
  # @spec AUTOMATION-PHASES-008
  class CompleteContinuationGrants
    def self.call(...)
      new(...).call
    end

    def initialize(work_items:, endpoint:)
      @work_items = Array(work_items)
      @endpoint = endpoint.to_s
    end

    def call
      return 0 if work_items.empty?

      WorkItemContinuationGrant.active
        .where(project_id: project_ids, issue_id: chain_issue_ids, endpoint:)
        .update_all(completed_at: Time.current, updated_at: Time.current)
    end

    private

    attr_reader :endpoint, :work_items

    def project_ids
      work_items.map(&:project_id).uniq
    end

    def chain_issue_ids
      direct_ids = work_items.map(&:id)
      root_ids = direct_ids | work_items.filter_map(&:parent_issue_id)
      root_ids | Issue.where(parent_issue_id: root_ids, is_pull_request: true).pluck(:id)
    end
  end
end
