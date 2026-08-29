# frozen_string_literal: true

module Knowledge
  class RunnerExecutor
    class AllRunnersExhausted < StandardError; end

    def initialize(user_setting:, operation:, knowledge_run: nil)
      @user_setting = user_setting
      @operation = operation
      @knowledge_run = knowledge_run
    end

    def execute
      runners = available_runners
      if runners.empty?
        log_runners_unavailable("no_available_runners")
        raise AllRunnersExhausted, "No available runners for #{@operation}"
      end

      last_error = nil

      runners.each_with_index do |runner, index|
        record_attempt(runner)
        rotation_attempts = 0

        begin
          result = yield(runner)
          record_success(runner)
          return result
        rescue AgentHarness::RateLimitError => e
          record_rate_limit(runner, e)
          # Rotate to the next free model and re-attempt the same runner at
          # most once. `retry` re-enters this begin block, so a rate-limited
          # rotated model (or any other AgentHarness::Error on the retry) is
          # re-caught here instead of escaping execute: a second rate-limit
          # fails the runner over to the next one in the chain. The single
          # retry is bounded because free_model_id_for only records the
          # highest-tier model as rate-limited, so an unbounded loop could
          # ping-pong between lower-tier models that are never recorded.
          if rotation_runner?(runner) && rotation_attempts.zero? && try_rotation(runner, e)
            rotation_attempts += 1
            retry
          end
          log_runner_failure(runner, "rate_limited", e)
          log_runner_switch(runner, runners[index + 1], "rate_limited", e)
          last_error = e
          next
        rescue AgentHarness::Error => e
          record_failure(runner, e)
          log_runner_failure(runner, "runner_error", e)
          log_runner_switch(runner, runners[index + 1], "runner_error", e)
          last_error = e
          next
        end
      end

      log_runners_unavailable("all_runners_exhausted", error: last_error)
      raise AllRunnersExhausted, "All runners exhausted for #{@operation}: #{last_error&.message}"
    end

    private

    def record_attempt(runner)
      @knowledge_run&.record_runner_attempt(runner)
    end

    def record_success(runner)
      @knowledge_run&.update!(final_runner: runner)
      state = runner_state_for(runner)
      fully_recovered = state&.record_success!
      restore_preferred_tier_model_ids(runner) if fully_recovered
    end

    # After a full recovery (per-model rate-limit windows cleared), restore
    # the openrouter_free runner's original tier_model_ids from the rotation
    # recovery snapshot so the user's configured models are not permanently
    # overridden by a rate-limit-driven rotation. No-op for non-rotation
    # runners or when no snapshot exists.
    def restore_preferred_tier_model_ids(runner)
      record = rotation_runner_record(runner)
      return unless record

      FreeModels::Rotation.restore_preferred!(runner: record, user: @user_setting.user)
    end

    def record_rate_limit(runner, error)
      reset_at = error.respond_to?(:reset_time) ? error.reset_time : nil
      state = runner_state_for(runner)
      state&.mark_rate_limited!(reset_at: reset_at)

      if (model_id = free_model_id_for(runner))
        state&.mark_model_rate_limited!(model_id, reset_at: reset_at)
      end
    end

    def record_failure(runner, _error)
      state = runner_state_for(runner)
      state&.record_failure!(
        threshold: @user_setting.circuit_breaker_failure_threshold,
        decay_window: @user_setting.circuit_breaker_timeout_seconds
      )
    end

    def available_runners
      case @operation.to_sym
      when :embedding
        Knowledge::RunnerSelector.for_embedding(user_setting: @user_setting)
      when :chat
        Knowledge::RunnerSelector.for_chat(user_setting: @user_setting)
      else
        raise ArgumentError, "Unsupported operation: #{@operation}"
      end
    end

    # Keyed by the resolved free-model runner's free_model_rotation_state_key
    # when one exists, so writes land on the same RunnerState row
    # FreeModels::Rotation reads rate_limited_model_ids from (routing key for
    # policy-based free runners, bare "openrouter_free" for the legacy row).
    # Falls back to the bare name passed in for every other runner.
    def runner_state_for(runner)
      @runner_states ||= {}
      @runner_states[runner] ||= @user_setting.user
        .runner_states
        .find_or_create_by!(runner_name: runner_state_key_for(runner)) { |s|
          s.circuit_state = "closed"
          s.failure_count = 0
        }
    end

    def runner_state_key_for(runner)
      rotation_runner_record(runner)&.free_model_rotation_state_key || runner.to_s
    end

    # Returns the free-policy Runner record for the current user when the
    # runner identifier points at one. The Runner record is what
    # FreeModels::Rotation needs in order to update tier_model_ids and read
    # the RunnerState.
    #
    # Memoized per runner-name. In the retry path this is invoked several
    # times for the same name (record_rate_limit -> free_model_id_for,
    # rotation_runner?, try_rotation, then record_success ->
    # restore_preferred_tier_model_ids), so caching avoids repeated find_by
    # queries. Uses Hash#key? rather than ||= so nil results (non-free-policy
    # names and missing-runner records) are cached too.
    def rotation_runner_record(runner_name)
      @rotation_runner_records ||= {}
      key = runner_name.to_s
      return @rotation_runner_records[key] if @rotation_runner_records.key?(key)

      record = Runner.for_identifier(@user_setting.user, key)
      @rotation_runner_records[key] = record&.free_model_policy? ? record : nil
    end

    def rotation_runner?(runner)
      rotation_runner_record(runner).present?
    end

    # Best-effort guess at which model the free-policy runner was using
    # when it rate-limited, used only when the error itself carries no model
    # id. Knowledge calls lean on the high-tier model, so walk tiers from
    # high down to low and return the first one the runner is configured for.
    def free_model_id_for(runner)
      record = rotation_runner_record(runner)
      return nil unless record

      LlmModel::TIERS.reverse_each do |tier|
        model_id = record.tier_model_ids&.dig(tier)
        return model_id if model_id.present?
      end

      nil
    end

    # Attempts to rotate the free-policy runner to a new free model and,
    # on success, records the rotation so the caller can retry with the same
    # runner. Returns the rotation result on success and nil when no
    # candidate is available (caller falls back to the next runner).
    def try_rotation(runner, error)
      record = rotation_runner_record(runner)
      return nil unless record

      result = FreeModels::Rotation.call(
        runner: record,
        current_model_id: extract_rate_limited_model_id(error),
        user: @user_setting.user,
        include_below_quality_bar: false
      )

      if result.rotated?
        Rails.logger.info(
          message: "knowledge.free_model_rotation",
          operation: @operation.to_s,
          runner: runner,
          previous_model_id: result.previous_model_id,
          new_model_id: result.model_id,
          tier: result.tier,
          knowledge_run_id: @knowledge_run&.id,
          user_setting_id: @user_setting.id
        )
      end

      result.rotated? ? result : nil
    end

    def extract_rate_limited_model_id(error)
      return nil unless error.respond_to?(:model_id)

      error.model_id.presence
    end

    def log_runner_failure(runner, reason, error)
      Rails.logger.warn(
        message: "knowledge.runner_failure",
        operation: @operation.to_s,
        runner: runner,
        reason: reason,
        error_class: error.class.name,
        error: error.message,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      )
    end

    def log_runner_switch(from_runner, to_runner, reason, error)
      return if to_runner.blank?

      Rails.logger.warn(
        message: "knowledge.runner_switch",
        operation: @operation.to_s,
        from_runner: from_runner,
        to_runner: to_runner,
        reason: reason,
        error_class: error.class.name,
        error: error.message,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      )
    end

    def log_runners_unavailable(reason, error: nil)
      payload = {
        message: "knowledge.runners_unavailable",
        operation: @operation.to_s,
        reason: reason,
        runners: available_runners_for_logging,
        knowledge_run_id: @knowledge_run&.id,
        user_setting_id: @user_setting.id
      }
      payload[:error_class] = error.class.name if error
      payload[:error] = error.message if error

      Rails.logger.warn(payload)
    end

    def available_runners_for_logging
      case @operation.to_sym
      when :embedding
        configured_runners(:kb_embedding_runner, :kb_embedding_fallback_runners)
      when :chat
        configured_runners(:kb_chat_runner, :kb_chat_fallback_runners)
      else
        []
      end
    end

    def configured_runners(primary_key, fallback_key)
      [ @user_setting.public_send(primary_key), *Array(@user_setting.public_send(fallback_key)) ]
        .filter_map { |runner| runner.to_s.strip.downcase.presence }
        .uniq
    end
  end
end
