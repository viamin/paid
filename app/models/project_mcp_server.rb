# frozen_string_literal: true

class ProjectMcpServer < ApplicationRecord
  belongs_to :project
  belongs_to :mcp_server_definition

  validates :mcp_server_definition_id, uniqueness: { scope: :project_id }
  validate :definition_belongs_to_same_account, if: -> { mcp_server_definition.present? && project.present? }

  private

  def definition_belongs_to_same_account
    return if mcp_server_definition.account_id == project.account_id

    errors.add(:mcp_server_definition, "must belong to the same account as the project")
  end
end
