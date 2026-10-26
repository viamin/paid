# frozen_string_literal: true

module QueueStalls
  # A stable digest of the state a stall assessment was derived from.
  #
  # The digest covers the issue's own facts and the blockers that were
  # recorded for it, so a changed blocker set is a new state and is assessed
  # again, while an unchanged state is not.
  # @spec QUEUE-DIAG-005
  class StateDigest
    def self.call(...)
      new(...).call
    end

    def initialize(issue:, reason_code:, blockers: [], closeout_evidence: nil)
      @issue = issue
      @reason_code = reason_code
      @blockers = blockers
      @closeout_evidence = closeout_evidence
    end

    def call
      Digest::SHA256.hexdigest(canonical.join(";"))[0, 32]
    end

    private

    attr_reader :issue, :reason_code, :blockers, :closeout_evidence

    def canonical
      [
        reason_code,
        issue.id,
        issue.paid_state.to_s,
        Array(issue.labels).map(&:to_s).sort.join(","),
        blockers.map { |blocker| "#{blocker.code}:#{blocker.owner}" }.sort.join("|"),
        closeout_evidence&.digest.to_s
      ]
    end
  end
end
