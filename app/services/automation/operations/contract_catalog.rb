# frozen_string_literal: true

module Automation
  module Operations
    # RDR-077 §6: the initial inventory of operational capabilities and their
    # handoffs. This records ownership and activation contracts for
    # capabilities that already exist; it adds no autonomous remediation.
    #
    # The same contract data is documented in
    # docs/intent/automation-phases/operations-ownership.md, and the spec
    # asserts the two cannot drift.
    #
    # @spec AUTOMATION-PHASES-018
    module ContractCatalog
      REQUIRED_FIELDS = %i[capability status signal_source activation_policy response_scope limits escalation handoff evidence].freeze

      Contract = Struct.new(*REQUIRED_FIELDS, keyword_init: true) do
        def complete?
          REQUIRED_FIELDS.all? { |field| public_send(field).to_s.strip.present? }
        end
      end

      CONTRACTS = [
        Contract.new(
          capability: "exception_incident_handling",
          status: "shipped",
          signal_source: "Actionable application exceptions passed to ExceptionHandler::Handle with optional project context.",
          activation_policy: "Always captures platform safety signals; the Operations phase does not gate capture or issue filing.",
          response_scope: "Fingerprints, records, rate-limits, classifies, and notifies an ExceptionIncident.",
          limits: "Five occurrences per fingerprint per hour and 500 incident occurrences per account per hour.",
          escalation: "P1 incidents publish error notifications; actionable project incidents may be handed to issue filing.",
          handoff: "An incident handoff does not authorize issue preparation or coding; normal delivery policy remains required.",
          evidence: "app/services/exception_handler/handle.rb; spec/services/exception_handler/handle_spec.rb"
        ),
        Contract.new(
          capability: "incident_issue_filing",
          status: "shipped",
          signal_source: "A project-scoped, allowlisted ExceptionIncident without a recorded GitHub issue.",
          activation_policy: "ExceptionHandler::Handle invokes filing for actionable allowlisted incidents; it is not Operations-phase-gated.",
          response_scope: "Creates one GitHub issue or appends an occurrence comment to its existing issue.",
          limits: "One filing claim per incident with a five-minute stale-claim recovery window.",
          escalation: "GitHub failures release the claim for retry; concurrent filing retries rather than creating duplicate issues.",
          handoff: "Creating a remediation issue does not authorize issue preparation or coding; only independently applicable delivery policy can do so.",
          evidence: "app/services/exception_handler/issue_filer.rb; spec/services/exception_handler/issue_filer_spec.rb"
        ),
        Contract.new(
          capability: "incident_triage",
          status: "shipped",
          signal_source: "Blocking notifications and incident records.",
          activation_policy: "Notifications publish independently of the Operations phase; phase ownership governs only project-scoped Inbox relevance when the rollout is enabled.",
          response_scope: "Routes blocking project notifications to the operator Inbox with their existing severity, evidence, and recovery action.",
          limits: "Per-user notification budget and notification severity gates.",
          escalation: "Notification backlog escalates per docs/intent/notification-severity.",
          handoff: "Triage either hands off to a delivery phase through explicit authorization or closes the incident.",
          evidence: "app/services/inbox/phase_ownership.rb; spec/services/inbox/phase_ownership_spec.rb"
        ),
        Contract.new(
          capability: "auto_release_evaluation",
          status: "shipped",
          signal_source: "Release Please pull-request and CI signals from a project GitHub client.",
          activation_policy: "Requires Release & Deployment phase authorization and the release control; there is no deployment control consumer.",
          response_scope: "Evaluates and may merge an eligible release PR; it does not publish an artifact or deploy software.",
          limits: "One evaluation per project at a time and configured release granularity.",
          escalation: "Parse, CI, and expected merge failures are recorded as auto-merge attempts for the release PR.",
          handoff: "A merged release PR does not authorize deployment; deployment remains an unshipped, separately controlled follow-up.",
          evidence: "app/temporal/activities/evaluate_auto_release_activity.rb; app/jobs/auto_release_evaluation_job.rb; spec/jobs/auto_release_evaluation_job_spec.rb"
        ),
        Contract.new(
          capability: "incoming_error_reports",
          status: "follow_up",
          signal_source: "No distinct shipped inbound error-report producer; ordinary GitHub issues use the normal sync path.",
          activation_policy: "No Operations activation exists for this capability.",
          response_scope: "No runtime response exists beyond normal issue handling.",
          limits: "No dedicated persistence, deduplication, or rate limit exists.",
          escalation: "No dedicated Inbox classification or escalation exists.",
          handoff: "A future producer must create a remediation issue without granting issue preparation or coding authority.",
          evidence: "app/services/exception_handler/issue_filer.rb; app/models/issue.rb"
        ),
        Contract.new(
          capability: "deployment_execution",
          status: "follow_up",
          signal_source: "No shipped project deployment completion signal or executor exists.",
          activation_policy: "The deployment subordinate setting has no execution consumer.",
          response_scope: "No deployment, deployment validation, or operational regression handoff exists.",
          limits: "No deployment budget or delivery executor exists.",
          escalation: "No deployment failure notification path exists.",
          handoff: "A future deployment capability must remain independently authorized from release and coding.",
          evidence: "app/services/automation/phase_settings.rb; app/services/automation/feature_activation.rb"
        )
      ].freeze

      PLATFORM_REQUESTS = %w[
        platform_health
        credential_status
        safety_guards
      ].freeze

      module_function

      def contracts
        CONTRACTS
      end

      def complete?
        CONTRACTS.all?(&:complete?)
      end

      def capability_names
        CONTRACTS.map(&:capability)
      end

      def shipped_capabilities
        capabilities_with_status("shipped")
      end

      def follow_up_capabilities
        capabilities_with_status("follow_up")
      end

      def capabilities_with_status(status)
        CONTRACTS.filter_map { |contract| contract.capability if contract.status == status }
      end
    end
  end
end
