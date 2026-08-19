# frozen_string_literal: true

module ExecutionRunners
  # Owns the provisioning-intent ledger lifecycle so each runner's +#provision+
  # stays thin (RDR-060). A runner builds a ledger from its declared capabilities
  # and calls {#record_intent} BEFORE the provider create call, then
  # {#link_created}, {#link_handle}, or {#mark_failed} as the provision advances.
  #
  # Recording the intent is required before the create call — the runner lets a
  # record failure propagate rather than create a resource it cannot reconcile.
  # The post-create transitions are best-effort: a ledger UPDATE must never mask
  # a successful handle return or a provisioning failure.
  #
  # The ledger is append-only across the provision lifecycle; cleanup does not
  # delete the row, so a full provision history remains for auditing.
  #
  # @spec CONTAINER-RUNTIME-022
  # @spec CONTAINER-RUNTIME-024
  class ProvisioningLedger
    # @param runner_type [String, Symbol] runner type (matches RunnerHandle#runner_type)
    # @param resource_kind [String, nil] resource kind the runner provisions; nil
    #   disables the ledger because the runner cannot attribute a created resource
    # @param environment [String] Paid deployment identifier (ownership tag)
    # @param supports_tagging [Boolean] whether the runner/provider can tag
    # @param supports_listing [Boolean] whether the runner/provider can list
    def initialize(runner_type:, resource_kind:, environment:, supports_tagging:, supports_listing:)
      @runner_type = runner_type.to_s
      @resource_kind = resource_kind.to_s.presence
      @environment = environment.to_s
      @supports_tagging = supports_tagging
      @supports_listing = supports_listing
    end

    # Whether this ledger records anything. A runner that cannot identify a
    # resource kind provisions without recording a ledger row.
    def recording?
      @resource_kind.present?
    end

    # The next per-run/resource attempt ordinal for a provisioning intent.
    # Counts persisted ledger rows so retries/reprovisions advance the
    # ownership-tag attempt instead of always reusing 0.
    # @param agent_run [AgentRun, nil]
    # @return [Integer]
    def next_attempt_for(agent_run:)
      return 0 unless recording? && agent_run

      ProvisioningIntent
        .where(agent_run_id: agent_run.id, resource_kind: @resource_kind)
        .count
    end

    # The ownership labels a tagging-capable runner applies to the provider
    # resource. Empty (and the runner is expected to degrade explicitly) when
    # the runner cannot tag or the ledger is disabled.
    # @param agent_run [AgentRun, nil]
    # @param attempt [Integer]
    # @return [Hash{String=>String}] provider label map
    # @spec CONTAINER-RUNTIME-023
    def ownership_labels_for(agent_run:, attempt: 0)
      ownership_tags_for(agent_run, attempt: attempt)&.to_label_map || {}
    end

    # Records a pending provisioning-intent row BEFORE the provider create call.
    # Returns the created {ProvisioningIntent}, or nil when the ledger is
    # disabled. Raises on persistence failure so a runner never proceeds to
    # create a resource it cannot reconcile.
    # @return [ProvisioningIntent, nil]
    # @spec CONTAINER-RUNTIME-022
    def record_intent(agent_run:, attempt: 0)
      return unless recording?

      warn_capability_degradations
      ProvisioningIntent.create!(
        runner_type: @runner_type,
        resource_kind: @resource_kind,
        environment: @environment,
        account_id: agent_run&.project&.account_id,
        project_id: agent_run&.project&.id,
        agent_run_id: agent_run&.id,
        attempt: Integer(attempt || 0),
        # The ownership tags mirror what is actually applied to the live
        # resource, so an unsupported-tagging degradation records no tags
        # rather than intended-but-unapplied tags that reconciliation could
        # never match against a live resource.
        ownership_tags: ownership_labels_for(agent_run: agent_run, attempt: attempt),
        tagging_supported: @supports_tagging,
        status: ProvisioningIntent::STATUS_PENDING,
        metadata: degradation_metadata
      )
    end

    # Captures the provider resource identifier once the create call succeeds,
    # advancing the row to +created+. Best-effort: a failure here must not mask
    # the successful creation. The row is already pending with the ownership
    # tags, so reconciliation still has attribution even if this update drops.
    # @spec CONTAINER-RUNTIME-022
    # @spec CONTAINER-RUNTIME-024
    def link_created(intent, provider_resource_id:, host:)
      return if intent.nil?

      intent.update!(provider_resource_id: provider_resource_id,
                     provider_resource_host: host, status: ProvisioningIntent::STATUS_CREATED)
    rescue StandardError => e
      log_ledger_failure("link_created", e, intent)
    end

    # Links the serialized runner handle once the runner builds it, advancing
    # the row to +linked+ (terminal success). Best-effort.
    def link_handle(intent, handle)
      return if intent.nil?

      intent.update!(runner_handle: handle.to_storage, status: ProvisioningIntent::STATUS_LINKED)
    rescue StandardError => e
      log_ledger_failure("link_handle", e, intent)
    end

    # Marks the intent failed when the provider create call failed or the
    # created resource was abandoned/cleaned up. Best-effort: a pending row with
    # no provider resource needs no reconciliation, so a failed-mark that drops
    # still leaves correct state.
    def mark_failed(intent)
      return if intent.nil?

      intent.update!(status: ProvisioningIntent::STATUS_FAILED)
    rescue StandardError => e
      log_ledger_failure("mark_failed", e, intent)
    end

    private

    def tagging_degraded?
      !@supports_tagging
    end

    def listing_degraded?
      !@supports_listing
    end

    # The ownership tags for a resource, or nil when the runner cannot tag (so
    # no tags are recorded or applied). Single source of truth for both the
    # provider labels and the ledger row.
    def ownership_tags_for(agent_run, attempt:)
      return nil unless recording? && @supports_tagging

      OwnershipTags.for(agent_run: agent_run, resource_kind: @resource_kind,
                        environment: @environment, attempt: attempt)
    end

    # Metadata recording an explicit degradation when the runner cannot tag.
    def degradation_metadata
      metadata = {}
      metadata["tagging_degraded"] = true if tagging_degraded?
      metadata["listing_degraded"] = true if listing_degraded?
      metadata["reason"] = degradation_reason if metadata.any?
      metadata
    end

    def degradation_reason
      reasons = []
      reasons << "runner_or_provider_cannot_tag" if tagging_degraded?
      reasons << "runner_or_provider_cannot_list" if listing_degraded?
      reasons.join(",")
    end

    def warn_capability_degradations
      warn_tagging_degradation if tagging_degraded?
      warn_listing_degradation if listing_degraded?
    end

    def warn_tagging_degradation
      log_capability_degradation(
        message: "execution_runners.tagging_unsupported_degraded",
        hint: "Ownership tags were not applied to the provider resource; reconciliation cannot locate orphans by tag."
      )
    end

    def warn_listing_degradation
      log_capability_degradation(
        message: "execution_runners.listing_unsupported_degraded",
        hint: "Runner cannot list provider resources; reconciliation must rely on direct handles or external provider visibility."
      )
    end

    def log_capability_degradation(message:, hint:)
      Rails.logger.warn(
        message: message,
        runner_type: @runner_type,
        resource_kind: @resource_kind,
        environment: @environment,
        hint: hint
      )
    end

    def log_ledger_failure(action, error, intent)
      Rails.logger.warn(
        message: "execution_runners.ledger_update_failed",
        action: action,
        runner_type: @runner_type,
        resource_kind: @resource_kind,
        intent_id: intent&.id,
        error: error.message
      )
    end
  end
end
