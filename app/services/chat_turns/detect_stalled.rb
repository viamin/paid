# frozen_string_literal: true

module ChatTurns
  # Finds chat turns that stopped producing durable activity and concludes
  # what happened to each one. A turn that really stalled is marked `stalled`,
  # a turn whose client left is marked `abandoned`, a turn that failed for a
  # known reason is marked `failed`, and a turn that is legitimately waiting is
  # left alone.
  #
  # @spec CHAT-TURN-RECOVERY-004
  class DetectStalled
    Summary = Data.define(:inspected, :stalled, :abandoned, :failed, :waiting, :recovered)

    def self.call(now: Time.current, limit: 200)
      new(now:, limit:).call
    end

    def initialize(now: Time.current, limit: 200)
      @now = now
      @limit = limit
    end

    def call
      summary = Summary.new(inspected: 0, stalled: 0, abandoned: 0, failed: 0, waiting: 0, recovered: 0)

      candidates.each do |turn|
        summary = process(turn, summary)
      rescue StandardError => error
        Rails.logger.error(
          message: "chat_turns.detect_stalled.turn_failed",
          chat_turn_id: turn.id,
          chat_session_id: turn.chat_session_id,
          error_class: error.class.name,
          error: error.message
        )
      end

      summary
    end

    private

    attr_reader :now, :limit

    # Only turns whose silence already exceeds the platform floor are
    # candidates; a tenant that waits longer is filtered out below.
    def candidates
      ChatTurn.open
        .where(last_activity_at: ...(now - ChatTurn.stall_threshold))
        .order(:last_activity_at)
        .limit(limit)
    end

    def process(turn, summary)
      outcome = Classify.call(turn)
      return waiting(turn, outcome, summary) unless actionable?(turn, outcome)

      case outcome.state
      when "stalled" then stalled(turn, outcome, summary)
      when "abandoned" then abandoned(turn, outcome, summary)
      else failed(turn, outcome, summary)
      end
    end

    # A tenant may wait longer than the platform floor before a quiet turn
    # counts as a stall.
    def conclusive?(turn, outcome)
      return true unless outcome.stalled

      turn.last_activity_at <= now - turn.stall_threshold
    end

    def actionable?(turn, outcome)
      conclusive?(turn, outcome) && outcome.state.in?(%w[stalled abandoned failed])
    end

    def waiting(turn, outcome, summary)
      record_classification(turn, outcome)
      summary.with(waiting: summary.waiting + 1, inspected: summary.inspected + 1)
    end
    def stalled(turn, outcome, summary)
      return summary.with(inspected: summary.inspected + 1) unless turn.mark_stalled!(classification: outcome.classification, at: now)

      record_classification(turn, outcome)
      recovered = request_automatic_recovery(turn)
      publish_notice(turn, outcome)
      summary.with(
        inspected: summary.inspected + 1,
        stalled: summary.stalled + 1,
        recovered: summary.recovered + (recovered ? 1 : 0)
      )
    end

    def abandoned(turn, outcome, summary)
      return summary.with(inspected: summary.inspected + 1) unless turn.mark_abandoned!(classification: outcome.classification, at: now)

      record_classification(turn, outcome)
      publish_notice(turn, outcome)
      summary.with(inspected: summary.inspected + 1, abandoned: summary.abandoned + 1)
    end

    def failed(turn, outcome, summary)
      return summary.with(inspected: summary.inspected + 1) unless turn.mark_failed!(classification: outcome.classification, at: now)

      record_classification(turn, outcome)
      summary.with(inspected: summary.inspected + 1, failed: summary.failed + 1)
    end

    def record_classification(turn, outcome)
      record_classification_event(turn, outcome)
      update_side_effect_flag(turn)
    end

    # A turn that keeps waiting is re-classified on every sweep, so the event
    # is written once per classification instead of once per sweep.
    def record_classification_event(turn, outcome)
      already = turn.events.classified.where(outcome: outcome.classification).exists?
      return if already

      turn.record_event(
        event_type: "classified",
        outcome: outcome.classification,
        metadata: { state: outcome.state, explanation: outcome.explanation }
      )
    end

    def update_side_effect_flag(turn)
      completed = transcript(turn).side_effecting_tools_completed?
      return if turn.side_effecting_tools_completed == completed

      turn.update!(side_effecting_tools_completed: completed)
    end

    def transcript(turn)
      @transcripts ||= {}
      @transcripts[turn.id] ||= ChatTurns::Transcript.call(turn)
    end

    def publish_notice(turn, outcome)
      return if StallNotice.already_published?(turn)

      StallNotice.call(
        turn: turn,
        transcript: transcript(turn),
        classification: outcome.classification,
        explanation: outcome.explanation
      )
    end

    # Automatic recovery is opt-in per failure classification: only a turn that
    # produced no output at all and ran no side-effecting tool is replayed
    # unattended.
    # @spec CHAT-TURN-RECOVERY-008
    def request_automatic_recovery(turn)
      return false unless turn.automatic_recovery_eligible?
      return false unless automatic_recovery_enabled?(turn)

      ChatTurns::RequestRecovery.call(turn: turn, source: :automatic)
      true
    rescue StandardError => error
      Rails.logger.error(
        message: "chat_turns.detect_stalled.automatic_recovery_failed",
        chat_turn_id: turn.id,
        error_class: error.class.name,
        error: error.message
      )
      false
    end

    def automatic_recovery_enabled?(turn)
      setting = turn.chat_session.account.tenant_setting
      return true unless setting

      setting.chat_automatic_stall_recovery
    end
  end
end
