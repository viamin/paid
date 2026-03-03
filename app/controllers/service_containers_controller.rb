# frozen_string_literal: true

class ServiceContainersController < ApplicationController
  before_action :set_service_container, only: [ :show, :edit, :update, :destroy ]
  skip_after_action :verify_authorized, only: :index
  skip_after_action :verify_policy_scoped, only: :index

  def index
    authorize ServiceContainer
    @service_containers = ServiceContainer.order(created_at: :desc)
  end

  def show
    authorize @service_container
  end

  def new
    @service_container = ServiceContainer.new(status: "stopped")
    authorize @service_container
  end

  def create
    @service_container = ServiceContainer.new(service_container_params)
    @service_container.status = "stopped"
    authorize @service_container

    if @service_container.save
      redirect_to @service_container, notice: "Service container was successfully created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @service_container
  end

  def update
    authorize @service_container

    if @service_container.update(service_container_params)
      redirect_to @service_container, notice: "Service container was successfully updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @service_container
    @service_container.destroy!
    redirect_to service_containers_path, notice: "Service container was successfully deleted."
  end

  private

  def set_service_container
    @service_container = ServiceContainer.find(params[:id])
  end

  def service_container_params
    params.require(:service_container).permit(:image, :name, :port, :env_json)
  end
end
