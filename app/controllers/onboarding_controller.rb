# frozen_string_literal: true

class OnboardingController < ApplicationController
  before_action :ensure_onboarding_needed
  before_action :set_onboarding_steps
  skip_after_action :verify_authorized

  def show
    @current_step = current_account.current_onboarding_step
    redirect_to dashboard_path if @current_step.nil?
  end

  def update
    step_name = params[:step]
    onboarding_step = current_account.onboarding_steps.find_by!(step: step_name)

    case step_name
    when "account_profile"
      complete_account_profile
    when "github_token"
      complete_github_token
    when "first_project"
      complete_first_project
    when "configure_defaults"
      complete_configure_defaults
    end
  rescue ActiveRecord::RecordInvalid => e
    @current_step = onboarding_step
    flash.now[:alert] = e.record.errors.full_messages.join(", ")
    render :show, status: :unprocessable_content
  end

  def skip
    step_name = params[:step]
    Onboarding::SkipStep.call(account: current_account, step: step_name)
    redirect_to_next_step
  rescue ArgumentError => e
    redirect_to onboarding_path, alert: e.message
  end

  private

  def ensure_onboarding_needed
    return unless current_account.onboarding_completed?

    redirect_to dashboard_path
  end

  def set_onboarding_steps
    @steps = current_account.onboarding_steps.ordered
    @progress = current_account.onboarding_progress
  end

  def complete_account_profile
    current_account.update!(
      name: params.dig(:account, :name)
    )
    Onboarding::CompleteStep.call(account: current_account, step: "account_profile")
    redirect_to_next_step
  end

  def complete_github_token
    token = current_account.github_tokens.build(
      name: params.dig(:github_token, :name),
      token: params.dig(:github_token, :token)
    )
    token.created_by = current_user
    token.save!
    GithubTokenValidationJob.perform_later(token.id)
    Onboarding::CompleteStep.call(
      account: current_account,
      step: "github_token",
      metadata: { github_token_id: token.id }
    )
    redirect_to_next_step
  end

  def complete_first_project
    project = current_account.projects.build(first_project_params)
    project.created_by = current_user
    project.allowed_github_usernames = [ project.owner ] if project.allowed_github_usernames.blank?

    fetch_and_save_project(project)
  end

  def complete_configure_defaults
    Onboarding::ProvisionDefaults.call(account: current_account)
    Onboarding::CompleteStep.call(account: current_account, step: "configure_defaults")
    redirect_to dashboard_path, notice: "Welcome to Paid! Your workspace is ready."
  end

  def first_project_params
    params.require(:project).permit(:name, :owner, :repo, :github_token_id)
  end

  def fetch_and_save_project(project)
    client = project.github_token.client
    repo_data = client.repository("#{project.owner}/#{project.repo}")

    project.github_id = repo_data.id
    project.name = project.name.presence || repo_data.name
    project.default_branch = repo_data.default_branch
    project.save!

    Onboarding::CompleteStep.call(
      account: current_account,
      step: "first_project",
      metadata: { project_id: project.id }
    )
    redirect_to_next_step
  rescue GithubClient::Error => e
    @current_step = current_account.onboarding_steps.find_by(step: "first_project")
    flash.now[:alert] = "GitHub error: #{e.message}"
    render :show, status: :unprocessable_content
  end

  def redirect_to_next_step
    next_step = current_account.current_onboarding_step
    if next_step
      redirect_to onboarding_path
    else
      redirect_to dashboard_path, notice: "Welcome to Paid! Your workspace is ready."
    end
  end
end
