# frozen_string_literal: true

module Projects
  class PostDeployMeasurementsController < ApplicationController
    before_action :set_project

    # @spec POST-DEPLOY-001
    def create
      authorize @project, :run_agent?
      issue = @project.issues.find(params[:issue_id])
      result = PostDeployMeasurements::Request.call(
        issue: issue,
        check_key: params[:check_key],
        criterion: criterion_param(issue),
        actor: current_user,
        prerequisite_identity: params[:prerequisite_identity].presence
      )
      # The bounded sweep executes the request once the target revision is
      # deployed; requesting never runs the check inline.
      PostDeployMeasurementSweepJob.perform_later
      redirect_to inbox_entry_redirect_target,
        notice: "Post-deploy measurement requested: #{result.measurement.check_key} v#{result.measurement.check_version}. " \
                "It runs automatically after the target revision is deployed."
    rescue PostDeployMeasurements::Registry::UnknownCheck, PostDeployMeasurements::Request::Unauthorized,
      ActiveRecord::RecordNotFound, ArgumentError => error
      redirect_to inbox_entry_redirect_target, alert: error.message
    end

    private

    def set_project = @project = policy_scope(Project).find(params[:project_id])

    # The exact criterion text comes from the bound prerequisite occurrence
    # when one is supplied, so the recorded evidence names what it measured.
    def criterion_param(issue)
      identity = params[:prerequisite_identity].presence
      occurrence = identity && prerequisite_notification(issue)
        &.then { |notification| PartialCloseouts::PrerequisiteOccurrences.for(notification)
          .find { |candidate| candidate["identity"] == identity } }
      occurrence&.fetch("criterion", nil).presence || params[:criterion].to_s.presence ||
        PostDeployMeasurements::Registry.find!(params[:check_key]).criterion
    end

    def prerequisite_notification(issue)
      @prerequisite_notification ||= Notification.find_by(
        account: @project.account,
        subject: issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        resolved_at: nil,
        dismissed_at: nil
      )
    end

    def inbox_entry_redirect_target
      entry_id = params[:inbox_entry_id].presence
      entry_id ? inbox_entry_path(entry_id) : inbox_path
    end
  end
end
