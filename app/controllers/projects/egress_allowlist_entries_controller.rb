# frozen_string_literal: true

# Project-scoped CRUD over egress allowlist entries.
#
# Project admins add project-specific host patterns here. Account-wide
# entries are managed via {Accounts::EgressAllowlistEntriesController}.
# Project entries may extend (but never narrow) what the account admin
# allowed; the resolver is responsible for merging both sets.
module Projects
  class EgressAllowlistEntriesController < ApplicationController
    before_action :set_project
    before_action :set_entry, only: [ :show, :update, :destroy ]

    def index
      authorize @project, :show?
      load_entries
    end

    def show
      authorize @entry
      respond_to do |format|
        format.html { redirect_to project_egress_allowlist_entries_path(@project) }
        format.json { render json: @entry }
      end
    end

    def create
      authorize @project, :update?

      @entry = @project.egress_allowlist_entries.build(entry_params)
      @entry.account = @project.account
      @entry.created_by ||= current_user

      if @entry.save
        record_project_activity(action: "egress_allowlist.project_entry_created",
          metadata: { host_pattern: @entry.host_pattern })
        redirect_to project_egress_allowlist_entries_path(@project),
          notice: "Allowlist entry added for #{@entry.host_pattern}."
      else
        load_entries
        render :index, status: :unprocessable_content
      end
    end

    def update
      authorize @entry

      if @entry.update(entry_params)
        record_project_activity(action: "egress_allowlist.project_entry_updated",
          metadata: { host_pattern: @entry.host_pattern, enabled: entry_params[:enabled] })
        redirect_to project_egress_allowlist_entries_path(@project),
          notice: entry_update_notice
      else
        load_entries
        render :index, status: :unprocessable_content
      end
    end

    def destroy
      authorize @entry
      host_pattern = @entry.host_pattern
      @entry.destroy!

      record_project_activity(action: "egress_allowlist.project_entry_removed",
        metadata: { host_pattern: host_pattern })

      redirect_to project_egress_allowlist_entries_path(@project),
        notice: "Allowlist entry removed for #{host_pattern}."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_entry
      @entry = @project.egress_allowlist_entries.find(params[:id])
    end

    def load_entries
      @entries = @project.egress_allowlist_entries.ordered
      @can_manage = policy(@project).update?
      @account_entries = @project.account.egress_allowlist_entries.for_account(@project.account).enabled.ordered
    end

    def entry_params
      params.require(:egress_allowlist_entry).permit(
        :host_pattern, :scheme, :port, :enabled, :reason
      )
    end

    def record_project_activity(action:, metadata:)
      Accounts::RecordActivity.call(
        account: @project.account,
        actor: current_user,
        action: action,
        subject: @project,
        metadata: metadata
      )
    end

    def entry_update_notice
      if entry_params.key?(:enabled)
        entry_params[:enabled].to_s == "false" ? "Allowlist entry disabled." : "Allowlist entry enabled."
      else
        "Allowlist entry updated."
      end
    end
  end
end
