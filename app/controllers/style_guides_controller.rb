# frozen_string_literal: true

class StyleGuidesController < ApplicationController
  before_action :set_style_guide, only: [ :show, :edit, :update, :destroy, :compress ]
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(StyleGuide).includes(:project, :account)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "name asc" if @q.sorts.empty?
    @pagy, @style_guides = pagy(@q.result)
  end

  def show
    authorize @style_guide
  end

  def new
    @style_guide = current_account.style_guides.build
    authorize @style_guide
    @projects = policy_scope(Project).order(:name)
  end

  def create
    @style_guide = build_style_guide
    authorize @style_guide

    detect_language_if_blank

    if @style_guide.save
      redirect_to @style_guide, notice: "Style guide was successfully created."
    else
      @projects = policy_scope(Project).order(:name)
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @style_guide
    @projects = policy_scope(Project).order(:name)
  end

  def update
    authorize @style_guide

    if @style_guide.update(style_guide_params)
      detect_language_if_blank
      @style_guide.save if @style_guide.changed?
      redirect_to @style_guide, notice: "Style guide was successfully updated."
    else
      @projects = policy_scope(Project).order(:name)
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @style_guide
    @style_guide.destroy!
    redirect_to style_guides_path, notice: "Style guide was successfully deleted."
  end

  def compress
    authorize @style_guide, :compress?

    StyleGuides::Compress.call(style_guide: @style_guide)
    redirect_to @style_guide, notice: "Style guide was successfully compressed."
  rescue AgentHarness::Error => e
    redirect_to @style_guide, alert: "Compression failed: #{e.message}"
  end

  private

  def set_style_guide
    @style_guide = policy_scope(StyleGuide).find(params[:id])
  end

  def build_style_guide
    if style_guide_params[:project_id].present?
      project = policy_scope(Project).find(style_guide_params[:project_id])
      project.style_guides.build(style_guide_params.except(:project_id).merge(account: project.account))
    else
      current_account.style_guides.build(style_guide_params.except(:project_id))
    end
  end

  def style_guide_params
    params.require(:style_guide).permit(:name, :raw_content, :language, :active, :project_id)
  end

  def detect_language_if_blank
    return if @style_guide.language.present?

    detected = StyleGuides::DetectLanguage.call(content: @style_guide.raw_content)
    @style_guide.language = detected if detected
  end
end
