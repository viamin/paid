# frozen_string_literal: true

class ModelsSyncJob < ApplicationJob
  queue_as :default

  def perform
    Models::SyncFromRegistry.call
  end
end
