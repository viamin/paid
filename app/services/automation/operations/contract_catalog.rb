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
      REQUIRED_FIELDS = %i[capability signal_source activation_policy response_scope limits escalation handoff].freeze

      Contract = Struct.new(*REQUIRED_FIELDS, keyword_init: true) do
        def complete?
          REQUIRED_FIELDS.all? { |field| public_send(field).to_s.strip.present? }
        end
      end

      CONTRACTS = [
        Contract.new(
          capability: "elevated_error_monitoring",
          signal_source: "Application error and health-check telemetry ingested from a project container.",
          activation_policy: "Requires the project's Operations phase enabled; never starts remediation work.",
          response_scope: "Records and notifies an incident, classifies its severity.",
          limits: "Notification volume bounded by incident severity and the per-project incident rate.",
          escalation: "Untriaged incidents past the age threshold escalate to an Inbox request.",
          handoff: "May open a remediation issue; that handoff does not authorize issue preparation or coding."
        ),
        Contract.new(
          capability: "incoming_error_reports",
          signal_source: "Operator- or agent-filed issue reports on project runtime behavior.",
          activation_policy: "Requires the Operations phase enabled; each response is an explicit manual action.",
          response_scope: "Records the report and links it to project runtime evidence.",
          limits: "One open incident per project and fingerprint.",
          escalation: "Reports that match no incident escalate to a classification-gap Inbox request.",
          handoff: "Remediation returns to its delivery phase only through explicit authorization."
        ),
        Contract.new(
          capability: "incident_triage",
          signal_source: "Blocking notifications and incident records.",
          activation_policy: "Always on; the Operations phase governs project-scoped visibility only.",
          response_scope: "Routes the request to the operator Inbox with severity, evidence, and recovery action.",
          limits: "Per-user notification budget and notification severity gates.",
          escalation: "Notification backlog escalates per docs/intent/notification-severity.",
          handoff: "Triage either hands off to a delivery phase through explicit authorization or closes the incident."
        ),
        Contract.new(
          capability: "release_deployment_validation",
          signal_source: "Release and deployment completion signals.",
          activation_policy: "Requires the Release & Deployment phase enabled plus the matching release or deployment control.",
          response_scope: "Validates the published artifact or the completed deployment.",
          limits: "Per-project release granularity and deployment budget.",
          escalation: "Failed validation escalates to a blocking notification in Operations.",
          handoff: "Regression after delivery hands back to Coding through explicit authorization."
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
    end
  end
end