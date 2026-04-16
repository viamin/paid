# frozen_string_literal: true

module PromptReviews
  # Approves a pending evolved prompt version and promotes it to be the
  # prompt's current version.
  #
  # @example
  #   PromptReviews::Approve.call(
  #     prompt_version: evolved_version,
  #     reviewer: current_user,
  #     notes: "LGTM"
  #   )
  class Approve
    attr_reader :prompt_version, :reviewer, :notes, :promote

    def initialize(prompt_version:, reviewer:, notes: nil, promote: true)
      @prompt_version = prompt_version
      @reviewer = reviewer
      @notes = notes
      @promote = promote
    end

    def self.call(...)
      new(...).approve
    end

    def approve
      validate!

      prompt = prompt_version.prompt
      prompt.with_lock do
        prompt_version.update!(
          review_status: "approved",
          reviewed_by_user: reviewer,
          reviewed_at: Time.current,
          review_notes: notes
        )
        prompt.update!(current_version: prompt_version) if promote
      end
      prompt_version
    end

    private

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "prompt version is not pending review" unless prompt_version.pending_review?
    end
  end
end
