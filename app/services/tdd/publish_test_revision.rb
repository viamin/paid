# frozen_string_literal: true

module Tdd
  # Publishes the red-phase review gate after a test-writing run has actually
  # shipped a commit. The local record changes only after every remote label
  # operation succeeds, so a partial GitHub failure cannot masquerade as a
  # fresh reviewable revision.
  # @spec TDD-PR-007
  class PublishTestRevision
    READY_LABEL = Tdd::ReturnToTestReview::TESTS_READY_FOR_REVIEW_LABEL
    VERDICT_LABELS = [
      Tdd::ReturnToTestReview::TESTS_APPROVED_LABEL,
      Projects::EnsureStandardLabels::LABEL_DEFINITIONS.dig(:tdd_test_changes_requested, :name)
    ].freeze

    Result = Data.define(:success, :error) do
      def success? = success
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, pull_request_number: nil)
      @agent_run = agent_run
      @pull_request_number = pull_request_number || agent_run.source_pull_request_number || agent_run.pull_request_number
    end

    def call
      return failure(:not_test_writing_phase) unless agent_run.tdd_test_writing_phase?
      return failure(:no_published_commit) if agent_run.result_commit_sha.blank?
      return failure(:no_pull_request) if pull_request_number.blank?

      return update_local_gate if project.label_integration_mode == "ignored"
      return failure(:no_github_client) unless project.client

      update_remote_labels
      update_local_labels
      Result.new(success: true, error: nil)
    rescue GithubClient::Error, Faraday::Error => e
      Rails.logger.warn(
        message: "tdd.publish_test_revision_label_sync_failed",
        agent_run_id: agent_run.id,
        pull_request_number: pull_request_number,
        error_class: e.class.name,
        error: e.message
      )
      failure(:label_sync_failed)
    end

    private

    attr_reader :agent_run, :pull_request_number

    def project
      agent_run.project
    end

    def update_remote_labels
      project.client.add_labels_to_issue(project.full_name, pull_request_number, [ READY_LABEL ])
      verdict_labels_to_remove.each do |label|
        project.client.remove_label_from_issue(project.full_name, pull_request_number, label)
      end
    end

    def update_local_gate
      pull_request = local_pull_request
      return failure(:no_local_pull_request) unless pull_request

      pull_request.update!(tdd_review_state: "ready_for_review", tdd_review_approved_at: nil)
      Result.new(success: true, error: nil)
    end

    def update_local_labels
      pull_request = local_pull_request
      return unless pull_request

      pull_request.with_lock do
        labels = (pull_request.labels - VERDICT_LABELS + [ READY_LABEL ]).uniq
        pull_request.update!(labels: labels)
      end
    end

    def local_pull_request
      project.issues.find_by(github_number: pull_request_number, is_pull_request: true)
    end

    def verdict_labels_to_remove
      Array(local_pull_request&.labels) & VERDICT_LABELS
    end

    def failure(error)
      Result.new(success: false, error: error)
    end
  end
end
