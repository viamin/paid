# frozen_string_literal: true

require "digest"
require "json"

module TrustedMeasurements
  # Surfaces the categories of trusted-measurement outcome Paid cannot
  # resolve on its own: a check key outside the allowlist, a deployment
  # revision Paid cannot currently identify, a check whose result violates
  # its own invariants, and a check that keeps failing instead of recovering.
  # Everything else (pending, running, and a current succeeded/unmet result)
  # routes only to the existing closeout/progress surfaces — never here — so
  # routine measurement activity never pages an operator.
  #
  # Idempotent: reuses the project's open escalation notification for the
  # same reason instead of creating a duplicate, and resolves it once the
  # condition clears.
  class Escalate
    SOURCE = "trusted_measurement_escalation"
    PERSISTENT_FAILURE_THRESHOLD = 3

    def self.call(attempt:) = new(attempt: attempt).call

    def self.source_for(check_key:, criterion_key:, external_issue_number:)
      fingerprint = Digest::SHA256.hexdigest(
        JSON.generate([ check_key, criterion_key, external_issue_number ])
      )[0, 16]
      "#{SOURCE}/#{fingerprint}"
    end

    def self.unauthorized(project:, check_key:, external_issue_number:, criterion_key:)
      publish(
        account: project.account, subject: project,
        source: source_for(check_key:, criterion_key:, external_issue_number:),
        title: "Trusted measurement check is not allowlisted",
        description: "#{check_key.inspect} is not an allowlisted trusted measurement check " \
          "(criterion #{criterion_key.inspect} on issue ##{external_issue_number}). " \
          "Add it to TrustedMeasurements::ALLOWLIST through a reviewed code change before it can run.",
        metadata: { "check_key" => check_key, "external_issue_number" => external_issue_number, "criterion_key" => criterion_key }
      )
    end

    def self.publish(account:, source:, subject:, title:, description:, metadata:)
      Notifications::Publish.call(
        account:, source:, subject:, severity: :error, blocking: true,
        nav_section: "projects", title: title, description: description, metadata: metadata
      )
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      return resolve! if resolved_condition?

      self.class.publish(
        account: attempt.account, subject: attempt.project,
        source: notification_source,
        title: title, description: description,
        metadata: {
          "attempt_id" => attempt.id, "check_key" => attempt.check_key,
          "criterion_key" => attempt.criterion_key, "external_issue_number" => attempt.external_issue_number
        }
      )
    end

    private

    attr_reader :attempt

    def resolved_condition?
      attempt.succeeded? && !contradictory? || (attempt.failed? && attempt.consecutive_failure_count < PERSISTENT_FAILURE_THRESHOLD)
    end

    def title
      return "Trusted measurement deployment revision is unknown" if missing_deployment_signal?
      return "Trusted measurement source issue is unavailable" if attempt.unknown?
      return "Trusted measurement is contradicting its own evidence" if contradictory?

      "Trusted measurement check keeps failing"
    end

    def description
      return "#{DeploymentSignal::ENV_KEY} is not set, so the #{attempt.check_key} measurement for issue " \
        "##{attempt.external_issue_number} cannot be bound to a deployed revision. Set #{DeploymentSignal::ENV_KEY} " \
        "in the deploy pipeline so this measurement can attest closeout evidence." if missing_deployment_signal?
      return "Issue ##{attempt.external_issue_number} is not available in this project's synchronized issue set, so " \
        "#{attempt.check_key} cannot be attached to its closeout evidence. Synchronize the issue, then retry." if attempt.unknown?
      return "The #{attempt.check_key} measurement for issue ##{attempt.external_issue_number} returned a closed-issue " \
        "count greater than its reported total, which cannot be true. Review the check definition before trusting " \
        "its evidence." if contradictory?

      "The #{attempt.check_key} measurement for issue ##{attempt.external_issue_number} has failed " \
        "#{attempt.consecutive_failure_count} times in a row (#{attempt.failure_reason}). Restore database " \
        "read access for this check and retry."
    end

    def contradictory?
      total = attempt.result["active_total"]
      closed = attempt.result["active_closed_issue_count"]
      total.is_a?(Integer) && closed.is_a?(Integer) && closed > total
    end

    def missing_deployment_signal?
      attempt.unknown? && attempt.failure_reason == "missing_deployment_signal"
    end

    def notification_source
      self.class.source_for(
        check_key: attempt.check_key,
        criterion_key: attempt.criterion_key,
        external_issue_number: attempt.external_issue_number
      )
    end

    def resolve!
      Notifications::Resolve.call(
        account: attempt.account,
        source: notification_source,
        subject: attempt.project
      )
    end
  end
end
