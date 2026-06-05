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
      @runner_states[runner] ||= @user_setting.user
        .runner_states
        .find_or_create_by!(runner_name: runner) { |s|
          s.circuit_state = "closed"
          s.failure_count = 0
        }
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
