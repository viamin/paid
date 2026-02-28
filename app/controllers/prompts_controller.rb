# frozen_string_literal: true

class PromptsController < ApplicationController
  before_action :set_prompt, only: [ :show, :edit, :update, :destroy, :diff ]
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(Prompt).includes(:current_version, :project, :account)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "name asc" if @q.sorts.empty?
    @pagy, @prompts = pagy(@q.result)
  end

  def show
    authorize @prompt
    @versions = @prompt.prompt_versions.includes(:created_by_user).order(version: :desc)
  end

  def new
    @prompt = current_account.prompts.build
    authorize @prompt
    @projects = policy_scope(Project).order(:name)
  end

  def create
    @prompt = build_prompt
    authorize @prompt

    ActiveRecord::Base.transaction do
      if @prompt.save
        if prompt_version_params[:template].present?
          @prompt.create_version!(
            template: prompt_version_params[:template],
            system_prompt: prompt_version_params[:system_prompt],
            variables: parse_variables,
            change_notes: "Initial version",
            created_by: "user",
            created_by_user: current_user
          )
        end
        redirect_to @prompt, notice: "Prompt was successfully created."
      else
        @projects = policy_scope(Project).order(:name)
        render :new, status: :unprocessable_content
      end
    end
  end

  def edit
    authorize @prompt
    @projects = policy_scope(Project).order(:name)
  end

  def update
    authorize @prompt

    ActiveRecord::Base.transaction do
      if @prompt.update(prompt_params)
        if version_content_changed?
          @prompt.create_version!(
            template: prompt_version_params[:template],
            system_prompt: prompt_version_params[:system_prompt],
            variables: parse_variables,
            change_notes: prompt_version_params[:change_notes],
            created_by: "user",
            created_by_user: current_user,
            parent_version: @prompt.current_version
          )
        end
        redirect_to @prompt, notice: "Prompt was successfully updated."
      else
        @projects = policy_scope(Project).order(:name)
        render :edit, status: :unprocessable_content
      end
    end
  end

  def destroy
    authorize @prompt
    @prompt.destroy!
    redirect_to prompts_path, notice: "Prompt was successfully deleted."
  end

  def diff
    authorize @prompt, :diff?

    a_id = params[:a]
    b_id = params[:b]

    if a_id.blank? || b_id.blank? || a_id == b_id
      redirect_back fallback_location: @prompt, alert: "You must select two different versions to compare."
      return
    end

    @version_a = @prompt.prompt_versions.find_by(id: a_id)
    @version_b = @prompt.prompt_versions.find_by(id: b_id)

    if @version_a.nil? || @version_b.nil?
      head :not_found
    end
  end

  private

  def set_prompt
    @prompt = policy_scope(Prompt).find(params[:id])
  end

  def build_prompt
    if prompt_params[:project_id].present?
      project = policy_scope(Project).find(prompt_params[:project_id])
      project.prompts.build(prompt_params.except(:project_id).merge(account: project.account))
    else
      current_account.prompts.build(prompt_params.except(:project_id))
    end
  end

  def prompt_params
    params.require(:prompt).permit(:name, :slug, :category, :description, :active, :project_id)
  end

  def prompt_version_params
    params.require(:prompt).permit(:template, :system_prompt, :variables_text, :change_notes)
  end

  def version_content_changed?
    return false if prompt_version_params[:template].blank?

    current = @prompt.current_version
    return true if current.nil?

    current.template != prompt_version_params[:template] ||
      current.system_prompt.to_s != prompt_version_params[:system_prompt].to_s ||
      normalize_variables(current.variables) != normalize_variables(parse_variables)
  end

  def normalize_variables(variables)
    Array(variables).map { |v|
      case v
      when Hash then (v["name"] || v[:name]).to_s.strip
      else v.to_s.strip
      end
    }.reject(&:blank?)
  end

  def parse_variables
    text = prompt_version_params[:variables_text].to_s.strip
    return [] if text.blank?

    text.split(",").map(&:strip).reject(&:blank?)
  end
end
