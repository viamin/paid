# frozen_string_literal: true

module ExceptionHandler
  # Central entry point for exception handling. Captures, fingerprints,
  # classifies, deduplicates, and takes appropriate action (log, notify,
  # or file an issue) for application exceptions.
  #
  # @example
  #   ExceptionHandler::Handle.call(
  #     exception: e,
  #     account: current_account,
  #     context: { subsystem: :knowledge, project_id: 42 }
  #   )
  class Handle
    RATE_LIMIT_THRESHOLD = 5
    RATE_LIMIT_WINDOW = 1.hour
    ACCOUNT_HOURLY_CAP = 500

    class Result
      attr_reader :incident, :action, :message

      def initialize(success:, incident: nil, action: nil, message: nil)
        @success = success
        @incident = incident
        @action = action
        @message = message
      end

      def success? = @success
      def failure? = !@success
    end

    def self.call(exception:, account:, context: {})
      new(exception: exception, account: account, context: context).call
    end

    def initialize(exception:, account:, context: {})
      @exception = exception
      @account = account
      @context = context
      @subsystem = context.fetch(:subsystem, "general").to_s
      @project = resolve_project
    end

    def call
      classification = nil
      incident = nil

      return account_cap_result if account_over_cap?

      fingerprint = Fingerprinter.call(exception: @exception, subsystem: @subsystem)
      existing = ExceptionIncident.find_by(account: @account, fingerprint: fingerprint)

      if existing && rate_limited?(existing)
        fast_path_increment(existing)
        return rate_limited_result(existing)
      end

      classification = Classifier.call(exception: @exception, subsystem: @subsystem)

      if classification.action == "logged"
        log_exception(classification, action: "logged")
        return logged_result(classification)
      end

      incident = if existing
        existing.record_occurrence!(new_context: occurrence_context)
        existing
      else
        create_incident(fingerprint, classification)
      end

      file_or_update_issue(incident, classification) if @project
      notify_if_needed(incident, classification)

      Result.new(success: true, incident: incident, action: incident.action_taken)
    rescue IssueFiler::RetryableFilingInProgress
      raise
    rescue => e
      Rails.logger.error(
        message: "exception_handler.handle_failed",
        original_exception: @exception.class.name,
        handler_error: e.message
      )
      Result.new(success: false, message: "Exception handler failed: #{e.message}")
    ensure
      log_actionable_exception(classification, incident)
    end

    private

    def log_actionable_exception(classification, incident)
      return unless classification
      return if classification.action == "logged"

      log_exception(classification, action: incident&.action_taken || classification.action)
    end

    def resolve_project
      project_id = @context[:project_id]
      return nil unless project_id

      @account.projects.find_by(id: project_id)
    end

    def log_exception(classification, action:)
      Rails.logger.public_send(
        classification.severity == "p1" ? :error : :warn,
        message: "exception_handler.captured",
        exception_class: @exception.class.name,
        exception_message: @exception.message&.truncate(500),
        subsystem: @subsystem,
        severity: classification.severity,
        action: action,
        reason: classification.reason,
        project_id: @project&.id
      )
    end

    def logged_result(classification)
      Result.new(
        success: true,
        action: "logged",
        message: "Transient exception logged: #{classification.reason}"
      )
    end

    def account_over_cap?
      ExceptionIncident.where(account: @account)
        .where("last_occurred_at > ?", RATE_LIMIT_WINDOW.ago)
        .sum(:occurrence_count) >= ACCOUNT_HOURLY_CAP
    end

    def rate_limited?(incident)
      incident.last_occurred_at > RATE_LIMIT_WINDOW.ago &&
        incident.occurrence_count >= RATE_LIMIT_THRESHOLD
    end

    def fast_path_increment(incident)
      incident.record_occurrence!(new_context: occurrence_context)
      Rails.logger.warn(
        message: "exception_handler.rate_limited",
        fingerprint: incident.fingerprint,
        occurrence_count: incident.occurrence_count
      )
    end

    def account_cap_result
      Rails.logger.error(
        message: "exception_handler.account_cap_dropped",
        account_id: @account.id,
        exception_class: @exception.class.name
      )
      Result.new(success: true, action: "logged", message: "Account hourly cap exceeded")
    end

    def rate_limited_result(incident)
      Result.new(
        success: true,
        incident: incident,
        action: incident.action_taken,
        message: "Rate-limited (per-fingerprint cap)"
      )
    end

    def create_incident(fingerprint, classification)
      ExceptionIncident.create!(
        account: @account,
        project: @project,
        fingerprint: fingerprint,
        exception_class: @exception.class.name,
        message: @exception.message.to_s.truncate(10_000),
        backtrace: @exception.backtrace&.first(20)&.join("\n"),
        subsystem: @subsystem,
        severity: classification.severity,
        action_taken: "notified",
        status: "open",
        context: occurrence_context,
        last_occurred_at: Time.current
      )
    end

    def occurrence_context
      {
        project_id: @project&.id,
        timestamp: Time.current.iso8601
      }.merge(@context.except(:subsystem, :project_id))
    end

    def file_or_update_issue(incident, classification)
      return if classification.action == "logged"

      target_project = @project
      return unless target_project
      return unless Classifier::ISSUE_FILING_ALLOWLIST.include?(@subsystem)

      if incident.github_issue_url.present? && incident.project_id != target_project.id
        Rails.logger.info(
          message: "exception_handler.skipped_cross_project_issue",
          incident_id: incident.id,
          original_project_id: incident.project_id,
          current_project_id: target_project.id
        )
        return
      end

      IssueFiler.call(incident: incident, project: target_project)
    end

    def notify_if_needed(incident, classification)
      return unless defined?(Notifications::Publish)

      severity = classification.severity == "p1" ? :error : :warning
      Notifications::Publish.call(
        account: @account,
        source: "exception_handler",
        subject: incident,
        severity: severity,
        title: "#{classification.severity.upcase}: #{@exception.class.name} in #{@subsystem}",
        description: @exception.message.to_s.truncate(500),
        metadata: {
          fingerprint: incident.fingerprint,
          occurrence_count: incident.occurrence_count,
          subsystem: @subsystem
        },
        nav_section: "dashboard"
      )
    end
  end
end
