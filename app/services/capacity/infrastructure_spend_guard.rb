# frozen_string_literal: true

module Capacity
  class InfrastructureSpendGuard
    GLOBAL_DAILY_SOURCE = "infra_spend_threshold_global_daily".freeze
    AUTO_CONTROL_SOURCE = "infrastructure_spend_threshold".freeze
    EVENT_THRESHOLD_BREACHED = "infrastructure_spend.threshold_breached".freeze
    EVENT_THRESHOLD_RECOVERED = "infrastructure_spend.threshold_recovered".freeze

    # @spec INFRA-SPEND-001
    # @spec INFRA-SPEND-004
    # @spec INFRA-SPEND-005
    def self.call(...)
      new(...).call
    end

    # Evaluates thresholds without recording notifications, audit events, or
    # flipping the global emergency control. Used when a decision is
    # speculative — e.g. one of several candidate hosts being compared during
    # capacity-aware host selection — so side effects are recorded at most
    # once, against the host that is actually chosen (see
    # ProcessRunQueueJob#finalize_infrastructure_spend!).
    def self.preview(...)
      new(...).preview
    end

    def self.recover_global_daily_threshold!(now: Time.current, env: ENV)
      new(account: nil, project: nil, selected_host: nil, now: now, env: env).recover_global_daily_threshold!
    end

    def initialize(account:, project:, selected_host:, agent_run: nil, runner: nil, now: Time.current, env: ENV)
      @account = account
      @project = project
      @selected_host = selected_host
      @agent_run = agent_run
      @runner = runner
      @now = now
      @env = env
    end

    def call
      evaluate(record_effects: true)
    end

    def preview
      evaluate(record_effects: false)
    end

    def recover_global_daily_threshold!
      limit_cents = Capacity::InfrastructureLimits.current(env: env)[:global_infra_spend_daily_limit_cents].to_i
      return disable_auto_global_control! if limit_cents <= 0

      check = threshold_checks.find { |entry| entry[:source] == GLOBAL_DAILY_SOURCE }
      return unless check

      current_spend_cents = spend_cents_for(check)
      projected_spend_cents = current_spend_cents + projected_cents_for(check)
      return if projected_spend_cents > check[:limit_cents]

      recover_threshold(check, current_spend_cents)
    end

    private

    def evaluate(record_effects:)
      first_breach = nil

      threshold_checks.each do |check|
        next if check[:limit_cents].to_i <= 0

        current_spend_cents = spend_cents_for(check)
        projected_spend_cents = current_spend_cents + projected_cents_for(check)
        if projected_spend_cents > check[:limit_cents].to_i
          record_breach(check, current_spend_cents, projected_spend_cents, check[:ends_at]) if record_effects
          first_breach ||= breach_payload(check, current_spend_cents, projected_spend_cents)
          next
        end

        recover_threshold(check, current_spend_cents) if record_effects
      end

      first_breach || { allowed: true }
    end

    attr_reader :account, :agent_run, :env, :now, :project, :runner, :selected_host

    def threshold_checks
      @threshold_checks ||= [
        build_check(
          scope: "global",
          period: "daily",
          action: "emergency_disable",
          source: GLOBAL_DAILY_SOURCE,
          limit_cents: limits[:global_infra_spend_daily_limit_cents]
        ),
        build_check(
          scope: "global",
          period: "hourly",
          action: "park",
          source: "infra_spend_threshold_global_hourly",
          limit_cents: limits[:global_infra_spend_hourly_limit_cents]
        ),
        build_check(
          scope: "account",
          period: "daily",
          action: "park",
          source: "infra_spend_threshold_account_daily",
          limit_cents: limits[:account_infra_spend_daily_limit_cents]
        ),
        build_check(
          scope: "account",
          period: "hourly",
          action: "park",
          source: "infra_spend_threshold_account_hourly",
          limit_cents: limits[:account_infra_spend_hourly_limit_cents]
        ),
        build_check(
          scope: "project",
          period: "daily",
          action: "park",
          source: "infra_spend_threshold_project_daily",
          limit_cents: limits[:project_infra_spend_daily_limit_cents]
        ),
        build_check(
          scope: "project",
          period: "hourly",
          action: "park",
          source: "infra_spend_threshold_project_hourly",
          limit_cents: limits[:project_infra_spend_hourly_limit_cents]
        ),
        build_check(
          scope: "runner",
          period: "daily",
          action: "fail_fast",
          source: "infra_spend_threshold_runner_daily",
          limit_cents: limits[:runner_infra_spend_daily_limit_cents]
        ),
        build_check(
          scope: "runner",
          period: "hourly",
          action: "fail_fast",
          source: "infra_spend_threshold_runner_hourly",
          limit_cents: limits[:runner_infra_spend_hourly_limit_cents]
        )
      ].select { |check| check[:subject].present? || check[:scope] == "global" }
    end

    def build_check(scope:, period:, action:, source:, limit_cents:)
      {
        scope: scope,
        period: period,
        action: action,
        source: source,
        limit_cents: limit_cents.to_i,
        starts_at: window_start_for(period),
        ends_at: window_end_for(period),
        account: account_for(scope),
        project: project_for(scope),
        runner: runner_for(scope),
        subject: subject_for(scope),
        notification_enabled: scope != "global"
      }
    end

    def account_for(scope)
      return account if scope == "account"
      return project.account if scope == "project" && project
      return runner.user.account if scope == "runner" && runner

      account
    end

    def project_for(scope)
      scope == "project" ? project : nil
    end

    def runner_for(scope)
      scope == "runner" ? runner : nil
    end

    def subject_for(scope)
      case scope
      when "account" then account
      when "project" then project
      when "runner" then runner
      end
    end

    def spend_cents_for(check)
      spend_cents_cache.fetch(check_cache_key(check)) do
        Capacity::InfrastructureSpend.spent_cents(
          account: check[:scope] == "global" ? nil : check[:account],
          project: check[:project],
          runner: check[:runner],
          starts_at: check[:starts_at],
          ends_at: now
        )
      end
    end

    def projected_cents_for(check)
      projected_cents_cache.fetch(check[:period]) do
        Capacity::InfrastructureSpend.projected_cents_for_host(
          host: selected_host,
          starts_at: check[:starts_at],
          ends_at: check[:ends_at],
          now: now,
          env: env
        )
      end
    end

    def check_cache_key(check)
      [ check[:scope], check[:period], check[:account]&.id, check[:project]&.id, check[:runner]&.id ]
    end

    def spend_cents_cache
      @spend_cents_cache ||= {}
    end

    def projected_cents_cache
      @projected_cents_cache ||= {}
    end

    def breach_payload(check, current_spend_cents, projected_spend_cents)
      {
        allowed: false,
        reason: "#{check[:scope]}_infra_spend_#{check[:period]}_limit_exceeded",
        rate_limited_until: check[:ends_at],
        spend_scope: check[:scope],
        spend_period: check[:period],
        spend_action: check[:action],
        current_spend_cents: current_spend_cents,
        projected_spend_cents: projected_spend_cents,
        infra_spend_limit_cents: check[:limit_cents]
      }
    end

    def recover_threshold(check, current_spend_cents)
      if check[:action] == "emergency_disable"
        recover_global_control(check, current_spend_cents)
      elsif check[:notification_enabled]
        recover_notification(check, current_spend_cents)
      end
    end

    def record_breach(check, current_spend_cents, projected_spend_cents, available_at)
      log_threshold_event("capacity.infrastructure_spend_threshold_breached", check, current_spend_cents, projected_spend_cents, available_at)
      ensure_notification(check, current_spend_cents, projected_spend_cents, available_at) if check[:notification_enabled]
      ensure_global_control(check, current_spend_cents, projected_spend_cents, available_at) if check[:action] == "emergency_disable"
    end

    def ensure_notification(check, current_spend_cents, projected_spend_cents, available_at)
      return unless check[:subject]

      existing = Notification.active.find_by(
        account: check[:account],
        source: check[:source],
        subject: check[:subject]
      )

      Notifications::Publish.call(
        account: check[:account],
        source: check[:source],
        subject: check[:subject],
        severity: check[:action] == "fail_fast" ? :warning : :error,
        title: notification_title(check),
        description: notification_description(check, current_spend_cents, projected_spend_cents, available_at),
        nav_section: notification_nav_section(check),
        metadata: notification_metadata(check, current_spend_cents, projected_spend_cents, available_at)
      )
      return if existing

      record_audit_event(
        EVENT_THRESHOLD_BREACHED,
        check,
        current_spend_cents,
        projected_spend_cents,
        available_at
      )
    end

    def recover_notification(check, current_spend_cents)
      return unless check[:subject]

      notification = Notifications::Resolve.call(
        account: check[:account],
        source: check[:source],
        subject: check[:subject]
      )
      return unless notification

      Rails.logger.info(
        message: "capacity.infrastructure_spend_threshold_recovered",
        scope: check[:scope],
        period: check[:period],
        current_spend_cents: current_spend_cents,
        limit_cents: check[:limit_cents],
        project_id: project&.id,
        runner_id: runner&.id
      )

      record_audit_event(
        EVENT_THRESHOLD_RECOVERED,
        check,
        current_spend_cents,
        current_spend_cents,
        check[:ends_at]
      )
    end

    def ensure_global_control(check, current_spend_cents, projected_spend_cents, available_at)
      control = ExecutionControl.find_or_initialize_by(scope: "global")
      return if control.persisted? && control.enabled? && control.metadata.to_h["source"] != AUTO_CONTROL_SOURCE

      existing_enabled = control.persisted? && control.enabled?
      control.assign_attributes(
        enabled: true,
        mode: "emergency",
        reason: "Automatic global daily infrastructure spend threshold exceeded",
        metadata: {
          "source" => AUTO_CONTROL_SOURCE,
          "period" => check[:period],
          "available_at" => available_at.iso8601,
          "limit_cents" => check[:limit_cents],
          "current_spend_cents" => current_spend_cents,
          "projected_spend_cents" => projected_spend_cents
        }
      )
      control.save!
      return if existing_enabled

      record_audit_event(
        EVENT_THRESHOLD_BREACHED,
        check,
        current_spend_cents,
        projected_spend_cents,
        available_at
      )
    end

    def recover_global_control(check, current_spend_cents)
      control = ExecutionControl.find_by(scope: "global", enabled: true)
      return unless control&.metadata.to_h["source"] == AUTO_CONTROL_SOURCE

      control.update!(
        enabled: false,
        metadata: control.metadata.to_h.merge(
          "recovered_at" => now.iso8601,
          "current_spend_cents" => current_spend_cents
        )
      )

      Rails.logger.info(
        message: "capacity.infrastructure_spend_threshold_recovered",
        scope: check[:scope],
        period: check[:period],
        current_spend_cents: current_spend_cents,
        limit_cents: check[:limit_cents]
      )

      record_audit_event(
        EVENT_THRESHOLD_RECOVERED,
        check,
        current_spend_cents,
        current_spend_cents,
        check[:ends_at]
      )
    end

    def disable_auto_global_control!
      control = ExecutionControl.find_by(scope: "global", enabled: true)
      return unless control&.metadata.to_h["source"] == AUTO_CONTROL_SOURCE

      control.update!(
        enabled: false,
        metadata: control.metadata.to_h.merge(
          "recovered_at" => now.iso8601,
          "disabled_by_threshold_config" => true
        )
      )

      Rails.logger.info(
        message: "capacity.infrastructure_spend_threshold_disabled",
        scope: "global",
        period: "daily"
      )
    end

    def notification_title(check)
      "#{check[:scope].humanize} infrastructure spend #{check[:period]} threshold reached"
    end

    def notification_description(check, current_spend_cents, projected_spend_cents, available_at)
      [
        "Current spend #{current_spend_cents}c, projected #{projected_spend_cents}c, limit #{check[:limit_cents]}c.",
        "New provisioning is #{check[:action].tr('_', ' ')} until #{available_at.iso8601}."
      ].join(" ")
    end

    def notification_metadata(check, current_spend_cents, projected_spend_cents, available_at)
      {
        scope: check[:scope],
        period: check[:period],
        action: check[:action],
        current_spend_cents: current_spend_cents,
        projected_spend_cents: projected_spend_cents,
        limit_cents: check[:limit_cents],
        available_at: available_at.iso8601
      }
    end

    def notification_nav_section(check)
      return "runners" if check[:scope] == "runner"

      "projects"
    end

    def log_threshold_event(message, check, current_spend_cents, projected_spend_cents, available_at)
      Rails.logger.warn(
        message: message,
        scope: check[:scope],
        period: check[:period],
        action: check[:action],
        current_spend_cents: current_spend_cents,
        projected_spend_cents: projected_spend_cents,
        limit_cents: check[:limit_cents],
        available_at: available_at.iso8601,
        agent_run_id: agent_run&.id,
        project_id: project&.id,
        runner_id: runner&.id,
        selected_host: selected_host
      )
    end

    def record_audit_event(event_name, check, current_spend_cents, projected_spend_cents, available_at)
      audit_account = check[:account] || project&.account || agent_run&.project&.account
      return unless audit_account

      ExecutionAuditEvent.record!(
        account: audit_account,
        project: check[:project] || project || agent_run&.project,
        agent_run: agent_run,
        event_name: event_name,
        actor_type: "system",
        actor_id: self.class.name,
        runner_key: runner&.runner_key,
        backend: selected_host,
        credential_classes: [ ExecutionAuditEvent::CREDENTIAL_CLASS_NONE ],
        metadata: {
          scope: check[:scope],
          period: check[:period],
          action: check[:action],
          current_spend_cents: current_spend_cents,
          projected_spend_cents: projected_spend_cents,
          limit_cents: check[:limit_cents],
          available_at: available_at.iso8601
        }
      )
    end

    def limits
      @limits ||= Capacity::InfrastructureLimits.current(host: selected_host, env: env)
    end

    def window_start_for(period)
      case period
      when "daily" then now.beginning_of_day
      else now.beginning_of_hour
      end
    end

    def window_end_for(period)
      case period
      when "daily" then now.beginning_of_day + 1.day
      else now.beginning_of_hour + 1.hour
      end
    end
  end
end
