# frozen_string_literal: true

# Account-scoped CRUD over egress allowlist entries.
#
# Account admins add account-wide host patterns here. Project-level entries
# are managed via {Projects::EgressAllowlistEntriesController}. Entries with
# unsafe rules (broad wildcards, paths, IP literals, loopback/metadata IPs)
# are rejected at the model boundary so the controller only needs to render
# the standard create/update form with the model's validation messages.
class Accounts::EgressAllowlistEntriesController < ApplicationController
  include AccountAdministrationPage

  before_action :load_account_administration_page
  before_action :set_entry, only: [ :show, :update, :destroy ]

  def index
    authorize EgressAllowlistEntry
    @entries = policy_scope(EgressAllowlistEntry)
      .for_account(current_account)
      .ordered
    @can_manage = policy(EgressAllowlistEntry).create?
  end

  def show
    authorize @entry
    respond_to do |format|
      format.html { redirect_to account_egress_allowlist_entries_path }
      format.json { render json: @entry }
    end
  end

  def create
    @entry = current_account.egress_allowlist_entries.new(entry_params)
    @entry.created_by ||= current_user
    authorize @entry

    if @entry.save
      record_audit_on_save(action: "egress_allowlist.account_entry_created", metadata: { host_pattern: @entry.host_pattern })
      redirect_to account_egress_allowlist_entries_path,
        notice: "Allowlist entry added for #{@entry.host_pattern}."
    else
      reload_index
      render :index, status: :unprocessable_content
    end
  end

  def update
    authorize @entry

    if @entry.update(entry_params)
      record_audit_on_save(action: "egress_allowlist.account_entry_updated",
        metadata: { host_pattern: @entry.host_pattern, enabled: @entry.enabled })
      redirect_to account_egress_allowlist_entries_path,
        notice: entry_update_notice
    else
      reload_index
      render :index, status: :unprocessable_content
    end
  end

  def destroy
    authorize @entry
    host_pattern = @entry.host_pattern
    @entry.destroy!

    Accounts::RecordActivity.call(
      account: current_account,
      actor: current_user,
      action: "egress_allowlist.account_entry_removed",
      metadata: { host_pattern: host_pattern }
    )

    redirect_to account_egress_allowlist_entries_path,
      notice: "Allowlist entry removed for #{host_pattern}."
  end

  private

  def set_entry
    @entry = policy_scope(EgressAllowlistEntry).for_account(current_account).find(params[:id])
  end

  def entry_params
    params.require(:egress_allowlist_entry).permit(
      :host_pattern, :scheme, :port, :enabled, :reason
    )
  end

  def reload_index
    @entries = policy_scope(EgressAllowlistEntry).for_account(current_account).ordered
    @can_manage = policy(EgressAllowlistEntry).create?
    load_account_administration_page
  end

  def record_audit_on_save(action:, metadata:)
    Accounts::RecordActivity.call(
      account: current_account,
      actor: current_user,
      action: action,
      metadata: metadata
    )
  rescue ActiveRecord::RecordNotFound
    # No-op if the user has been removed since the action was queued.
  end

  def entry_update_notice
    if entry_params.key?(:enabled)
      entry_params[:enabled].to_s == "false" ? "Allowlist entry disabled." : "Allowlist entry enabled."
    else
      "Allowlist entry updated."
    end
  end
end
