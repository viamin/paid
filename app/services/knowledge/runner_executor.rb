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

        begin
          result = yield(runner)
          record_success(runner)
          return result
        rescue AgentHarness::RateLimitError => e
          record_rate_limit(runner, e)
          if rotation_runner?(runner)
            rotated_result = try_rotation(runner, e)
            if rotated_result
              result = yield(runner)
              record_success(runner)
              return result
            end
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
      runner_state_for(runner)&.record_success!
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

    def runner_state_for(runner)
      @runner_states ||= {}
      @runner_states[runner] ||= begin
        state_name = runner_state_name_for(runner)
        @user_setting.user
          .runner_states
          .find_or_create_by!(runner_name: state_name) { |s|
            s.circuit_state = "closed"
            s.failure_count = 0
          }
      end
    end

    # Resolves the RunnerState key for the given runner identifier. Strings
    # that map to a configured Runner record use that record's state_key so
    # all state for one runner is grouped together (free-model rotation,
    # circuit-breaker updates, etc.); bare strings like "claude" or "openai"
    # use themselves so behavior matches the pre-existing callers.
    def runner_state_name_for(runner)
      record = rotation_runner_record(runner)
      return record.state_key if record

      runner.to_s
    end

    # Returns the openrouter_free Runner record for the current user when the
    # runner-name passed in is openrouter_free and the user actually has one
    # configured. The Runner record is what FreeModels::Rotation needs in
    # order to update tier_model_ids and read the RunnerState.
    def rotation_runner_record(runner_name)
      return nil unless runner_name.to_s == Runner::OPENROUTER_FREE_RUNNER_KEY

      user_runners = @user_setting.user.runners.kept_only
      user_runners.find_by(runner_key: Runner::OPENROUTER_FREE_RUNNER_KEY)
    end

    def rotation_runner?(runner)
      rotation_runner_record(runner).present?
    end

    def free_model_id_for(runner)
      record = rotation_runner_record(runner)
      return nil unless record

      LlmModel::TIERS.each do |tier|
        model_id = record.tier_model_ids&.dig(tier)
        return model_id if model_id.present?
      end

      nil
    end

    # Attempts to rotate the openrouter_free runner to a new free model and,
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
