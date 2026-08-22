# frozen_string_literal: true

module ExecutionAuditEvents
  class Lifecycle
    CREDENTIAL_CLASS_BY_DELIVERY = {
      "proxy_mode" => ExecutionAuditEvent::CREDENTIAL_CLASS_PROXY_RESTRICTED,
      "subscription_auth" => ExecutionAuditEvent::CREDENTIAL_CLASS_SUBSCRIPTION_AUTH,
      "direct_outbound" => ExecutionAuditEvent::CREDENTIAL_CLASS_DIRECT_OUTBOUND
    }.freeze

    class << self
      def record(event_name:, actor_id:, agent_run: nil, project: nil, account: nil, actor_type: "system",
        runner: nil, backend: nil, image_reference: nil, image_digest: nil, credential_classes: nil,
        networking_policy: nil, resource_type: nil, resource_id: nil, correlation_id: nil, metadata: {})
        run = agent_run
        resolved_project = project || run&.project
        resolved_account = account || resolved_project&.account
        resolved_policy = normalize_networking_policy(networking_policy)
        resolved_metadata = base_metadata(
          agent_run: run,
          correlation_id: correlation_id,
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
          runner_key: runner&.runner_key || run&.runner&.runner_key,
          backend: backend,
          image_reference: image_reference,
          image_digest: image_digest,
          credential_classes: normalize_credential_classes(
            credential_classes.presence || credential_classes_for(run, resolved_policy)
          ),
          network_policy: resolved_policy,
          resource_type: resource_type,
          resource_id: resource_id,
          correlation_id: normalize_correlation_id(correlation_id || run&.temporal_workflow_id),
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
        grants = Array(agent_run&.authority_grants&.dig("grants"))
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

      def base_metadata(agent_run:, correlation_id:, resource_id:, metadata:)
        result = stringify(metadata)
        workflow_id = normalize_correlation_id(correlation_id || agent_run&.temporal_workflow_id)
        result["temporal_workflow_id"] ||= workflow_id if workflow_id.present?
        request_id = current_request_id
        result["request_id"] ||= request_id if request_id.present?
        runner_handle_id = agent_run&.runner_handle&.dig("identifier")
        result["runner_handle_id"] ||= runner_handle_id if runner_handle_id.present?
        ledger_id = resource_ledger_id_for(agent_run: agent_run, resource_id: resource_id)
        result["resource_ledger_id"] ||= ledger_id if ledger_id.present?
        result
      end

      def resource_ledger_id_for(agent_run:, resource_id:)
        return if agent_run.blank? || resource_id.blank?

        agent_run.execution_resource_ledger_entries
          .where(provider_resource_id: resource_id)
          .order(id: :desc)
          .pick(:id)
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
