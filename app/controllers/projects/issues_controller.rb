# frozen_string_literal: true

module Projects
  class IssuesController < ApplicationController
    before_action :set_project
    before_action :set_issue

    # App -> GitHub: flips the local `paused` flag, which the Issue
    # `after_commit` callback mirrors onto GitHub by adding/removing the
    # `paid-paused` label. Best-effort: a GitHub failure is logged and the
    # next sync reconciles the label.
    def toggle_pause
      authorize @issue, policy_class: IssuePolicy

      @issue.update!(paused: !@issue.paused)

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            view_context.dom_id(@issue, :pause_toggle),
            partial: "projects/issue_pause_toggle",
            locals: { issue: @issue, project: @project }
          )
        end
        format.html { redirect_to project_path(@project, anchor: view_context.dom_id(@issue)) }
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_issue
      @issue = @project.issues.find(params[:id])
    end
  end
end
