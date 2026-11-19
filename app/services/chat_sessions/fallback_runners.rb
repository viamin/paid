# frozen_string_literal: true

require "set"

module ChatSessions
  module FallbackRunners
    module_function

    def for(chat_session:, excluding: [], required_zdr: false)
      # @spec CHAT-API-006
      user = chat_session.created_by
      return [] unless user&.settings

      excluded_ids = excluded_runner_ids(excluding)
      excluded_ids << chat_session.runner_id if excluding.blank? && chat_session.runner_id.present?
      current_runner = chat_session.reload.runner
      current_candidates = if usable_runner?(current_runner) && !excluded_ids.include?(current_runner.id)
        [ current_runner ]
      else
        []
      end

      configured_candidates = Array(user.settings.kb_chat_fallback_runners).filter_map do |identifier|
        runner = runner_for_identifier(user, identifier, excluding_ids: excluded_ids)
        next unless usable_runner?(runner)
        next if excluded_ids.include?(runner.id)

        runner
      end

      automatic_candidates = user.runners.kept_only.for_fallback.api_key
        .includes(:provider_api_key, :integration_credential)
        .for_chat.ordered.filter_map do |runner|
        next unless usable_runner?(runner)
        next if excluded_ids.include?(runner.id)

        runner
      end

      (current_candidates + configured_candidates + automatic_candidates).uniq.select do |runner|
        free_pool_available?(runner, chat_session: chat_session) &&
          curated_model_available?(runner, chat_session: chat_session) &&
          privacy_eligible?(runner, chat_session: chat_session, required_zdr: required_zdr)
      end
    end

    def switch!(chat_session:, runner:)
      # @spec CHAT-API-026
      resolution = CuratedModelOptions.resolve_with_diagnostics(runner:, projects: chat_session.llm_policy_projects) unless runner.free_model_policy?
      option = resolution&.option
      model = if runner.free_model_policy?
        FreeModels::SelectChatModel.for_session(runner: runner, chat_session: chat_session).model_id
      else
        option&.model_id ||
          raise(LlmClientConfigurationError, "No compatible chat model is available for #{runner.display_name}. Check the catalog, API availability, and operator policy.")
      end
      metadata = fallback_metadata(chat_session:, runner:, model:, option:, resolution:)
      # @spec CHAT-THINKING-EFFORT-005
      metadata = ThinkingEffort.normalize_metadata(metadata:, model_id: model)
      chat_session.update!(runner: runner, model: model, metadata: metadata)
    end

    # Provider fallback is attempt-local for explicit selections. The fallback
    # pair remains persisted long enough to describe that attempt, then the
    # next turn retries the user's saved preference.
    # @spec CHAT-API-026
    def restore_requested!(chat_session:)
      metadata = chat_session.metadata
      return unless metadata["requested_model_selection"] == "explicit"

      runner = chat_session.created_by.runners.kept_only.find_by(id: metadata["requested_runner_id"])
      model = metadata["requested_model"]
      return unless BuildLlmClient.usable_runner?(runner) && model.present?
      return if chat_session.runner_id == runner.id && chat_session.model == model

      restored_metadata = metadata.merge(
        "model_tier" => metadata["requested_model_tier"],
        "effective_model" => model,
        "effective_tier" => metadata["requested_model_tier"],
        "effective_runner_id" => runner.id,
        "model_substitution_reason" => nil
      ).compact
      chat_session.update!(runner:, model:, metadata: restored_metadata)
    end

    # @spec CHAT-API-019
    def free_pool_available?(runner, chat_session:)
      return true unless runner.free_model_policy?

      FreeModels::SelectChatModel.for_session(runner: runner, chat_session: chat_session)
      true
    rescue LlmClientConfigurationError
      false
    end

    # Non-free fallbacks resolve the requested tier preference, and switch! raises
    # LlmClientConfigurationError when none resolves. That error is not an
    # AgentHarness::Error, so FallbackLoop would abort instead of trying the
    # next configured fallback — skip such runners up front, mirroring the
    # free-pool skip above.
    # @spec CHAT-API-026
    def curated_model_available?(runner, chat_session:)
      return true if runner.free_model_policy?

      CuratedModelOptions.resolve(runner:, projects: chat_session.llm_policy_projects).present?
    end

    def fallback_metadata(chat_session:, runner:, model:, option:, resolution:)
      metadata = chat_session.metadata
      requested_model = metadata["requested_model"] || (chat_session.model if metadata["requested_model_selection"] != "automatic")
      requested_runner_id = metadata["requested_runner_id"] || (chat_session.runner_id if requested_model)
      requested_selection = requested_model ? "explicit" : "automatic"
      metadata.merge(
        "requested_model" => requested_model,
        "requested_runner_id" => requested_runner_id,
        "requested_model_selection" => requested_selection,
        "requested_model_tier" => (metadata["requested_model_tier"] || "low" if requested_selection == "automatic"),
        "model_tier" => option&.tier,
        "effective_model" => model,
        "effective_tier" => option&.tier,
        "effective_runner_id" => runner.id,
        "model_substitution_reason" => "fallback_runner"
      ).compact
    end

    # @spec MODEL-POLICY-024
    def privacy_eligible?(runner, chat_session:, required_zdr:)
      policy = runner.effective_privacy_policy(project: chat_session.llm_policy_project, required_zdr: required_zdr)
      return true unless policy.zdr_required

      runner.required_api_service_type != Runner::OPENROUTER_FREE_MODEL_PROVIDER && policy.eligible
    end

    def notice_for(error:, runner:)
      reason = if error.is_a?(AgentHarness::RateLimitError)
        "hit a rate limit"
      else
        "could not complete the request"
      end

      "The selected chat runner #{reason}: #{ErrorMessage.for(error)} Switching to #{runner.display_name} and continuing."
    end

    def usable_runner?(runner)
      BuildLlmClient.usable_runner?(runner)
    end

    # @spec RUNNER-USAGE-006
    # Chat fallback requires both the chat usage permission and the fallback
    # modifier — fallback never unlocks chat on its own.
    def runner_for_identifier(user, identifier, excluding_ids:)
      if Runner.routing_key?(identifier)
        runner = Runner.for_identifier(user, identifier)
        return nil if runner && excluding_ids.include?(runner.id)
        return nil unless runner&.enabled_for_chat?
        return nil unless runner&.enabled_for_fallback?

        runner
      else
        user.runners.kept_only.for_chat.for_fallback.where(runner_key: identifier).ordered.find do |runner|
          usable_runner?(runner) && !excluding_ids.include?(runner.id)
        end
      end
    end

    def excluded_runner_ids(runners)
      Array(runners).each_with_object(Set.new) do |runner, ids|
        next unless runner

        ids << runner.id
      end
    end
  end
end
