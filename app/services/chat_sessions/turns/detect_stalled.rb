# frozen_string_literal: true

module ChatSessions
  module Turns
    # Finds chat turns that stopped without a terminal outcome, records the
    # stall and its classification, and puts an actionable notice in the
    # transcript.
    #
    # The detector reads durable state only. A turn that is legitimately still
    # working — waiting on a human confirmation, parked on a provider quota
    # window, or running a tool that is declared long-running — is never
    # classified as stalled.
    class DetectStalled
      DEFAULT_THRESHOLD = 15.minutes
      # The scan bound: the query can only look this far back, so a large
      # threshold does not widen the scan.
      SCAN_THRESHOLD = 1.minute
      ABANDONMENT_WINDOW = 24.hours

      def self.call(...)
        new(...).call
      end

      def initialize(now: Time.current)
        @now = now
      end

      def call
        detected = 0

        TenantContext.with_system_access do
          candidates.find_each do |turn|
            next unless stallable?(turn)
            next unless mark_stalled(turn)

            detected += 1
          end
        end

        Rails.logger.info(
          message: "chat_turn.detect_stalled_complete",
          detected_count: detected,
          candidate_count: candidates_count
        ) if detected > 0

        detected
      end

      private

      attr_reader :now

      def candidates
        ChatTurn.active.where(last_activity_at: ...(now - SCAN_THRESHOLD)).includes(:chat_session)
      end

      def candidates_count
        @candidates_count ||= candidates.count
      end

      def stallable?(turn)
        chat_session = turn.chat_session
        return false if chat_session.archived? || chat_session.closed?
        return false if chat_session.rate_limited?
        return false if pending_confirmation?(chat_session)
        return false if long_running_in_flight?(turn)

        turn.last_activity_at < now - threshold_for(chat_session)
      end

      # A turn waiting on a human is not a stall: the human is the thing that
      # clears it.
      def pending_confirmation?(chat_session)
        chat_session.messages.pending_tool_confirmations.exists?
      end

      def long_running_in_flight?(turn)
        name = turn.evidence.in_flight_tool_name
        return false if name.blank?

        Tools::Registry.long_running?(name)
      end

      def threshold_for(chat_session)
        seconds = chat_session.account&.tenant_setting&.chat_turn_stall_threshold_seconds
        return DEFAULT_THRESHOLD unless seconds.is_a?(Integer) && seconds.positive?

        seconds.seconds
      end

      def mark_stalled(turn)
        classification = Classify.for(turn)
        updated = ChatTurn.where(id: turn.id, status: ChatTurn::ACTIVE_STATUSES).update_all(
          status: "stalled",
          stall_classification: classification,
          detected_at: now,
          stalled_at: now,
          updated_at: now,
          lock_version: Arel.sql("lock_version + 1")
        )
        return false if updated.zero?

        turn.reload
        record_detection(turn, classification)
        true
      end

      def record_detection(turn, classification)
        RecordEvent.call(
          turn: turn,
          event_type: "detected",
          metadata: {
            "classification" => classification,
            "detected_at" => now.iso8601,
            "last_activity_at" => turn.last_activity_at&.iso8601,
            "side_effecting_tool_names" => turn.evidence.side_effecting_tool_names,
            "in_flight_tool_name" => turn.evidence.in_flight_tool_name
          }
        )

        StallNotice.call(turn: turn)
        schedule_automatic_recovery(turn)
        publish_notification(turn)
      end

      def schedule_automatic_recovery(turn)
        return false unless ReplaySafety.for(turn).automatic_recovery_permitted?

        ChatSessions::Turns::RecoverJob.perform_later(
          chat_turn_id: turn.id,
          action: "resume",
          source: "automatic"
        )
        true
      end

      # A stalled turn is halted work. It is blocking only when nothing in the
      # system clears it on its own, per the notification-severity taxonomy.
      def publish_notification(turn)
        chat_session = turn.chat_session
        automatic = ReplaySafety.for(turn).automatic_recovery_permitted?

        Notifications::Publish.call(
          account: chat_session.account,
          user: chat_session.created_by,
          source: "chat_turn_stalled",
          subject: turn,
          severity: "error",
          blocking: !automatic,
          title: "Chat turn stalled",
          description: notification_description(turn),
          action_url: "/chat/#{chat_session.id}",
          nav_section: "chat",
          metadata: {
            "recommended_action" => "Resume the stalled turn from the chat transcript, or send a new message.",
            "turn_id" => turn.id,
            "chat_session_id" => chat_session.id,
            "classification" => turn.stall_classification,
            "detected_at" => turn.detected_at&.iso8601
          }
        )
      end

      def notification_description(turn)
        "A chat turn in this conversation stopped without an answer. " \
          "Classification: #{turn.stall_classification}. " \
          "Resume it from the transcript, or send a new message."
      end
    end
  end
end
