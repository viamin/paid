# frozen_string_literal: true

class Avo::Resources::StyleGuide < Avo::BaseResource
  self.title = :name
  self.model_class = ::StyleGuide
  self.authorization_policy = ::OperatorConsole::StyleGuidePolicy

  def fields
    field :id, as: :id
    field :name, as: :text, sortable: true
    field :account_id, as: :number
    field :project_id, as: :number
    field :language, as: :text, sortable: true
    field :active, as: :boolean, sortable: true
    field :compression_state, as: :badge, sortable: false, options: {
      success: "Compressed",
      warning: "Stale",
      danger: "Failed"
    } do
      record.compression_state.to_s.humanize
    end
    field :compressed_at, as: :date_time, readonly: true do
      record.last_compressed_at
    end
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end

  def actions
    action Avo::Actions::RecompressStyleGuides
  end
end
