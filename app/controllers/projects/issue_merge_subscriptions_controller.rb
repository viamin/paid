# frozen_string_literal: true

module Projects
  class IssueMergeSubscriptionsController < ApplicationController
    before_action :set_project
    before_action :set_issue

    def create
      authorize @issue, policy_class: IssueMergeSubscriptionPolicy

      retries = 0
      current_user.issue_merge_subscriptions.find_or_create_by!(
        issue: @issue,
        subscription_type: IssueMergeSubscription::ON_MERGE
      )

      respond_with_subscription_state(
        notice: "You will be notified when #{notification_target}."
      )
    rescue ActiveRecord::RecordNotUnique
      raise if (retries += 1) > 2

      retry
    end

    def destroy
      authorize @issue, policy_class: IssueMergeSubscriptionPolicy

      current_user.issue_merge_subscriptions.on_merge.where(issue: @issue).delete_all

      respond_with_subscription_state(
        notice: "Notifications for #{notification_target} were removed."
      )
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_issue
      @issue = @project.issues.find(params[:issue_id])
    end

    def respond_with_subscription_state(notice:)
      subscribed = current_user.issue_merge_subscriptions.on_merge.exists?(issue: @issue)

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            view_context.dom_id(@issue, :merge_subscription),
            partial: "projects/issue_merge_subscription",
            locals: {
              issue: @issue,
              project: @project,
              subscribed: subscribed
            }
          )
        end
        format.html { redirect_to project_path(@project, anchor: view_context.dom_id(@issue)), notice: notice }
      end
    end

    def notification_target
      if @issue.is_pull_request?
        "PR ##{@issue.github_number} is merged"
      else
        "issue ##{@issue.github_number} is completed"
      end
    end
  end
end
