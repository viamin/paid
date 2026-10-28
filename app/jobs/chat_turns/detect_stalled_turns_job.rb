# frozen_string_literal: true

# Detects chat turns that stopped without a terminal outcome, explains them in
# the transcript, and starts bounded recovery where the replay safety contract
# allows it.
#
# @spec CHAT-TURN-RECOVERY-004
class ChatTurns::DetectStalledTurnsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "chat_turn_detector"
  )

  def perform
    summary = ChatTurns::DetectStalled.call

    Rails.logger.info(
      message: "chat_turns.detect_stalled.completed",
      inspected: summary.inspected,
      stalled: summary.stalled,
      abandoned: summary.abandoned,
      failed: summary.failed,
      waiting: summary.waiting,
      recovered: summary.recovered
    )

    summary
  end
end
