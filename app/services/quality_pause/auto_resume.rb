# frozen_string_literal: true

module QualityPause
  # Resumes a quality-paused project after an automated corrective action,
  # unless the project has already cycled through too many auto-resumes.
  class AutoResume
    MAX_RESUMES = 3
    WINDOW = 24.hours
    NOTIFICATION_SOURCE = "quality_auto_resume_cooldown"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, reason:, metadata: {})
      @project = project
      @reason = reason
      @metadata = metadata
    end

    def call
      return Result.new(resumed: false, cooldown_limited: false) unless project.quality_paused?

      if cooldown_limited?
        publish_cooldown_alert
        log_cooldown_limit
        return Result.new(resumed: false, cooldown_limited: true)
      end

      resumed = project.quality_resume!(metadata: resume_metadata)
      resolve_cooldown_alert if resumed
      log_resume if resumed

      Result.new(resumed: resumed, cooldown_limited: false)
    end

    private

    attr_reader :project, :reason, :metadata

    def cooldown_limited?
      recent_auto_resumes_count >= MAX_RESUMES
    end

    def recent_auto_resumes_count
      @recent_auto_resumes_count ||= project.quality_pause_events.resumes
        .where(created_at: WINDOW.ago..)
        .where("metadata->>'auto_resumed' = ?", "true")
        .count
    end

    def resume_metadata
      metadata.merge(
        auto_resumed: true,
        reason: reason,
        cooldown_window_hours: WINDOW.to_i / 1.hour.to_i,
        recent_auto_resumes: recent_auto_resumes_count
      )
    end

    def publish_cooldown_alert
      Notifications::Publish.call(
        account: project.account,
        source: NOTIFICATION_SOURCE,
        subject: project,
        severity: :error,
        title: "Quality pause requires manual review for #{project.name}",
        description: "Automatic resume was stopped after #{MAX_RESUMES} quality recoveries in #{WINDOW.to_i / 1.hour.to_i} hours.",
        metadata: resume_metadata.merge(max_auto_resumes: MAX_RESUMES),
        action_url: "/projects/#{project.id}/quality_dashboard",
        nav_section: "projects"
      )
    end

    def resolve_cooldown_alert
      Notifications::Resolve.call(
        account: project.account,
        source: NOTIFICATION_SOURCE,
        subject: project
      )
    end

    def log_resume
      Rails.logger.info(
        message: "quality_pause.auto_resumed",
        project_id: project.id,
        reason: reason,
        recent_auto_resumes: recent_auto_resumes_count
      )
    end

    def log_cooldown_limit
      Rails.logger.warn(
        message: "quality_pause.auto_resume_cooldown_limited",
        project_id: project.id,
        reason: reason,
        recent_auto_resumes: recent_auto_resumes_count,
        max_auto_resumes: MAX_RESUMES,
        window_hours: WINDOW.to_i / 1.hour.to_i
      )
    end

    class Result
      def initialize(resumed:, cooldown_limited:)
        @resumed = resumed
        @cooldown_limited = cooldown_limited
      end

      def resumed?
        @resumed
      end

      def cooldown_limited?
        @cooldown_limited
      end
    end
  end
end
