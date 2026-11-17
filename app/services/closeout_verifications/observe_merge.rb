# frozen_string_literal: true

module CloseoutVerifications
  # Persists the authoritative merge fact before admission so reconciliation
  # can recover a missed observer without treating a merge as deployment.
  class ObserveMerge
    def self.call(...) = new(...).call

    def initialize(source_pr:, merge_commit_sha:)
      @source_pr = source_pr
      @merge_commit_sha = merge_commit_sha.to_s
    end

    def call
      return Admit::Outcome.new([], "merge_revision_missing") if merge_commit_sha.blank?

      source_pr.update!(merged_commit_sha: merge_commit_sha) unless source_pr.merged_commit_sha == merge_commit_sha
      Admit.call(source_pr:, merge_commit_sha:)
    end

    private

    attr_reader :merge_commit_sha, :source_pr
  end
end
