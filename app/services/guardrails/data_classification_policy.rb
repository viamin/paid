# frozen_string_literal: true

module Guardrails
  class DataClassificationPolicy
    include Runners::OpenRouterDataRouting

    DECISION_TYPE = "check_data_classification"
    DECISION_POINT = "data_classification_policy"

    Result = Data.define(
      :data_classification,
      :provider_data_collection,
      :provider_zdr,
      :warning_emitted,
      :warning_message
    ) do
      def warning?
        warning_emitted
      end

      def context
        {
          data_classification: data_classification,
          provider_data_collection: provider_data_collection,
          provider_zdr: provider_zdr
        }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, selection:)
      @agent_run = agent_run
      @selection = selection
    end

    def call
      result = build_result
      persist_decision(result)
      persist_warning_log(result) if result.warning?
      result
    end

    private

    attr_reader :agent_run, :selection

    # @spec FREE-MODEL-002, FREE-MODEL-003
    def build_result
      data_collection = routing_params[:data_collection]
      zdr = routing_params[:zdr]

      Result.new(
        data_classification: project.data_classification,
        provider_data_collection: data_collection,
        provider_zdr: zdr,
        warning_emitted: warning?,
        warning_message: warning_message(data_collection)
      )
    end

    def project
      agent_run.project
    end

    def model
      selection[:model]
    end

    # @spec FREE-MODEL-003
    def warning?
      return false unless sensitive_project?
      return false unless model&.free?
      return false unless model.data_training_risk == "possible"
      return false if openrouter_routed?

      true
    end

    def sensitive_project?
      project.confidential? || project.restricted?
    end

    def openrouter_routed?
      # Free-policy direct-outbound runners always send requests through
      # OpenRouter with data_collection/zdr set (see
      # Runners::FreeModelExecutionPlan), regardless of the selected model's
      # catalog_source — so treat them as OpenRouter-routed even for plain
      # DeepSeek/Qwen/etc rows.
      free_policy_openrouter_runner? || model&.catalog_source == "openrouter_sync"
    end

    def free_policy_openrouter_runner?
      runner = agent_run.runner
      runner&.free_model_policy? && runner.required_api_service_type == Runner::OPENROUTER_FREE_MODEL_PROVIDER
    end

    def runner_key
      agent_run.runner&.runner_key || agent_run.effective_runner
    end

    def routing_params
      return {} unless openrouter_routed?

      build_provider_routing(project)
    end

    def warning_message(data_collection)
      return unless warning?

      "Data classification warning: selected free model #{model.model_id} has possible training risk " \
        "for #{project.data_classification} project on runner #{runner_key}. " \
        "Use an OpenRouter-routed model to enforce provider data_collection=#{data_collection || "deny"}."
    end

    def persist_decision(result)
      OrchestrationDecision.record(
        project: project,
        issue: agent_run.issue,
        agent_run: agent_run,
        action: DECISION_TYPE,
        decision_point: DECISION_POINT,
        status: result.warning? ? "applied" : "noop",
        context: result.context,
        signals: {
          "runner_key" => runner_key,
          "model_id" => model&.model_id,
          "pricing_tier" => model&.pricing_tier,
          "data_training_risk" => model&.data_training_risk
        }.compact,
        result: {
          "warning_emitted" => result.warning?,
          "warning_message" => result.warning_message
        }.compact
      )
    end

    def persist_warning_log(result)
      agent_run.log!(
        "system",
        result.warning_message,
        metadata: {
          type: "data_classification_guardrail",
          data_classification: result.data_classification,
          provider_data_collection: result.provider_data_collection,
          provider_zdr: result.provider_zdr,
          model_id: model&.model_id,
          runner_key: runner_key
        }.compact
      )
    rescue StandardError => e
      Rails.logger.warn(
        message: "data_classification_policy.warning_log_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error_message: e.message
      )
    end
  end
end
