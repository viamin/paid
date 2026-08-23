# frozen_string_literal: true

module ExecutionAuditEvents
  class Lifecycle
    CREDENTIAL_CLASS_BY_DELIVERY = {
      "proxy_mode" => ExecutionAuditEvent::CREDENTIAL_CLASS_PROXY_RESTRICTED,
      "subscription_auth" => ExecutionAuditEvent::CREDENTIAL_CLASS_SUBSCRIPTION_AUTH,
      "direct_outbound" => ExecutionAuditEvent::CREDENTIAL_CLASS_DIRECT_OUTBOUND
    }.freeze
    RESOURCE_EVENT_PREFIX = "execution.resource_"

    class << self
      def record(event_name:, actor_id:, agent_run: nil, project: nil, account: nil, actor_type: "system",
        runner: nil, backend: nil, image_reference: nil, image_digest: nil, credential_classes: nil,
        networking_policy: nil, resource_type: nil, resource_id: nil, correlation_id: nil, metadata: {})
        run = agent_run
        resolved_project = project || run_project(run)
        resolved_account = account || project_account(resolved_project)
        resolved_policy = normalize_networking_policy(networking_policy)
        resolved_metadata = base_metadata(
          event_name: event_name,
          agent_run: run,
          correlation_id: correlation_id,
          resource_type: resource_type,
          resource_id: resource_id,
          metadata: metadata
        )

        ExecutionAuditEvent.record!(
          account: resolved_account,
          project: resolved_project,
          agent_run: run,
          run_attempt: run&.respond_to?(:run_attempt) ? run.run_attempt : nil,
          event_name: event_name,
          event_version: 1,
          actor_type: actor_type,
          actor_id: actor_id,
          runner_key: resolve_runner_key(runner, run),
          backend: backend,
          image_reference: image_reference,
          image_digest: image_digest,
          credential_classes: normalize_credential_classes(
            credential_classes.presence || credential_classes_for(run, resolved_policy)
          ),
          network_policy: resolved_policy,
          resource_type: resource_type,
          resource_id: resource_id,
          correlation_id: normalize_correlation_id(correlation_id || run_temporal_workflow_id(run)),
          metadata: resolved_metadata
        )
      rescue StandardError => error
        Rails.logger.error(
          message: "execution_audit.lifecycle_record_failed",
          event_name: event_name,
          agent_run_id: run&.id,
          error_class: error.class.name,
          error: error.message
        )
        nil
      end

      private

      def credential_classes_for(agent_run, networking_policy)
        grants = Array(run_authority_grants(agent_run)&.dig("grants"))
        classes = grants.filter_map do |grant|
          CREDENTIAL_CLASS_BY_DELIVERY[grant["delivery"].to_s]
        end
        classes << ExecutionAuditEvent::CREDENTIAL_CLASS_PROXY_RESTRICTED if classes.empty? && networking_policy["firewall"] == true
        classes.presence || [ ExecutionAuditEvent::CREDENTIAL_CLASS_NONE ]
      end

      def normalize_credential_classes(classes)
        Array(classes).map(&:to_s).uniq.presence || [ ExecutionAuditEvent::CREDENTIAL_CLASS_NONE ]
      end

      def normalize_networking_policy(policy)
        return {} if policy.blank?
        return stringify(policy) if policy.is_a?(Hash)

        {
          "mode" => policy.respond_to?(:mode) ? policy.mode.to_s : nil,
          "canonical_mode" => policy.respond_to?(:canonical_mode) ? policy.canonical_mode.to_s : nil,
          "firewall" => policy.respond_to?(:firewall?) ? policy.firewall? : nil,
          "allow_destinations" => normalize_allow_destinations(policy)
        }.compact
      end

      def normalize_allow_destinations(policy)
        Array(policy.respond_to?(:allow_destinations) ? policy.allow_destinations : []).map do |destination|
          stringify(destination)
        end
      end

      def base_metadata(event_name:, agent_run:, correlation_id:, resource_type:, resource_id:, metadata:)
        result = stringify(metadata)
        workflow_id = normalize_correlation_id(correlation_id || run_temporal_workflow_id(agent_run))
        result["temporal_workflow_id"] ||= workflow_id if workflow_id.present?
        request_id = current_request_id
        result["request_id"] ||= request_id if request_id.present?
        runner_handle_id = run_runner_handle_id(agent_run)
        result["runner_handle_id"] ||= runner_handle_id if runner_handle_id.present?
        ledger_id = resource_ledger_id_for(
          event_name: event_name,
          agent_run: agent_run,
          resource_type: resource_type,
          resource_id: resource_id
        )
        result["resource_ledger_id"] ||= ledger_id if ledger_id.present?
        result
      end

      # `ExecutionResourceLedgerEntry` rows are the long-term linkage target,
      # but the runtime provision/cleanup path does not create or update them
      # yet (RESOURCE-LEDGER-005, tracked by #3352/#3410) — only
      # `ExecutionRunners::ProvisioningLedger` writes `ProvisioningIntent`
      # rows today. Check the ledger first so linkage upgrades automatically
      # once RESOURCE-LEDGER-005 lands, and fall back to the provisioning
      # intent so the field is actually populated in the meantime.
      def resource_ledger_id_for(event_name:, agent_run:, resource_type:, resource_id:)
        return unless resource_event?(event_name: event_name, resource_type: resource_type, resource_id: resource_id)
        return if agent_run.blank? || !agent_run.respond_to?(:execution_resource_ledger_entries)

        matching_record_id(agent_run.execution_resource_ledger_entries, agent_run: agent_run, resource_id: resource_id) ||
          matching_record_id(ProvisioningIntent.where(agent_run_id: agent_run.id), agent_run: agent_run, resource_id: resource_id)
      end

      def resource_event?(event_name:, resource_type:, resource_id:)
        event_name.to_s.start_with?(RESOURCE_EVENT_PREFIX) || resource_type.present? || resource_id.present?
      end

      def matching_record_id(relation, agent_run:, resource_id:)
        id_by_provider_resource_id(relation, resource_id: resource_id) ||
          id_by_runner_handle(relation, agent_run: agent_run)
      end

      def id_by_provider_resource_id(relation, resource_id:)
        return if resource_id.blank?

        relation.where(provider_resource_id: resource_id).order(id: :desc).pick(:id)
      end

      # Falls back to matching the agent run's persisted runner handle when no
      # provider resource id is available (or no row matches it) — the only
      # durable identifier for execution-runner-backed resources.
      def id_by_runner_handle(relation, agent_run:)
        runner_handle_id = run_runner_handle_id(agent_run)
        return if runner_handle_id.blank?

        relation.where("runner_handle ->> 'identifier' = ?", runner_handle_id).order(id: :desc).pick(:id)
      end

      def run_project(run)
        run.project if run.respond_to?(:project)
      end

      def project_account(project)
        project.account if project.respond_to?(:account)
      end

      def resolve_runner_key(runner, run)
        return runner.runner_key if runner.respond_to?(:runner_key)

        persisted_runner = run.runner if run.respond_to?(:runner)
        persisted_runner.runner_key if persisted_runner&.respond_to?(:runner_key)
      end

      def run_authority_grants(run)
        run.authority_grants if run.respond_to?(:authority_grants)
      end

      def run_temporal_workflow_id(run)
        run.temporal_workflow_id if run.respond_to?(:temporal_workflow_id)
      end

      def run_runner_handle_id(run)
        return unless run.respond_to?(:runner_handle)

        run.runner_handle&.dig("identifier")
      end

      def current_request_id
        return unless defined?(Current) && Current.respond_to?(:request_id)

        Current.request_id
      end

      def normalize_correlation_id(value)
        return if value.blank? || value == AgentRun::CLAIMED_SENTINEL

        value
      end

      def stringify(value)
        ExecutionRunners.json_value(value)
      end
    end
  end
end
