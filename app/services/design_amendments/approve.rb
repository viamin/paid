# frozen_string_literal: true

module DesignAmendments
  # Records the human approval of an amended design PR head. The approval is
  # part of the amendment contract: a merged revision cannot be recorded
  # without it (RDR-067 §Human decision and amendment).
  # @spec INTENT-AMENDMENT-004
  class Approve
    def self.call(...)
      new(...).call
    end

    def initialize(amendment:, actor:, pr_head_sha:)
      @amendment = amendment
      @actor = actor
      @pr_head_sha = pr_head_sha
    end

    def call
      unless amendment.status.in?(%w[open approved])
        raise InvalidTransitionError, "cannot approve a #{amendment.status} amendment"
      end

      amendment.update!(
        status: "approved",
        approved_pr_head_sha: pr_head_sha,
        approved_by: actor,
        approved_at: Time.current
      )
    end

    private

    attr_reader :amendment, :actor, :pr_head_sha
  end
end
