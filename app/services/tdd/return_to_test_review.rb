# frozen_string_literal: true

module Tdd
  # Executes the one legitimate path for a test_fixing run to touch tests
  # under RDR-056: remove paid-tests-approved, add
  # paid-tests-ready-for-review, and record that the reset happened so
  # Tdd::WriteGuard stops rejecting test edits on this run.
  #
  # The label swap and the write-guard flag are applied together so the flag
  # can never be set without the PR actually being returned to test review —
  # a run cannot silently claim the reset happened.
  #
  # @example
  #   result = Tdd::ReturnToTestReview.call(agent_run: agent_run)
  #   result.success? # => true
  class ReturnToTestReview
    TESTS_READY_FOR_REVIEW_LABEL = Projects::EnsureStandardLabels::LABEL_DEFINITIONS.dig(:tdd_test_review, :name)
    TESTS_APPROVED_LABEL = Projects::EnsureStandardLabels::LABEL_DEFINITIONS.dig(:tdd_tests_approved, :name)

    Result = Data.define(:success, :error) do
      def success? = success
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return failure(:not_test_fixing_phase) unless agent_run.tdd_test_fixing_phase?
      return failure(:no_pull_request) if pull_request_number.blank?

      client = project.client
      return failure(:no_github_client) unless client

      result = swap_labels(client)
      return result unless result.success?

      agent_run.update!(tdd_returned_to_test_review: true)

      Result.new(success: true, error: nil)
    end

    private

    attr_reader :agent_run

    def project
      agent_run.project
    end

    def pull_request_number
      agent_run.source_pull_request_number || agent_run.pull_request_number
    end

    def swap_labels(client)
      client.remove_label_from_issue(project.full_name, pull_request_number, TESTS_APPROVED_LABEL)
      client.add_labels_to_issue(project.full_name, pull_request_number, [ TESTS_READY_FOR_REVIEW_LABEL ])
      update_local_pull_request_labels
      Result.new(success: true, error: nil)
    rescue GithubClient::Error, Faraday::Error => e
      Rails.logger.warn(
        message: "tdd.return_to_test_review_label_sync_failed",
        agent_run_id: agent_run.id,
        pull_request_number: pull_request_number,
        error_class: e.class.name,
        error: e.message
      )
      failure(:label_sync_failed)
    end

    def update_local_pull_request_labels
      pull_request = project.issues.find_by(github_number: pull_request_number, is_pull_request: true)
      return unless pull_request

      pull_request.with_lock do
        updated = (pull_request.labels - [ TESTS_APPROVED_LABEL ] + [ TESTS_READY_FOR_REVIEW_LABEL ]).uniq
        pull_request.update!(labels: updated)
      end
    end

    def failure(error)
      Result.new(success: false, error: error)
    end
  end
end
