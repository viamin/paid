# frozen_string_literal: true

module Strategies
  class ResolveVersion
    def self.call(...)
      new(...).call
    end

    def initialize(slug:, project: nil, account: nil)
      @slug = slug
      @project = project
      @account = account || project&.account
    end

    def call
      project_scope || account_scope || global_scope
    end

    private

    attr_reader :slug, :project, :account

    def project_scope
      return unless project

      resolve_active_version(
        Strategy.active
        .for_project(project)
        .includes(:current_version)
        .find_by(slug: slug)
      )
    end

    def account_scope
      return unless account

      resolve_active_version(
        Strategy.active
        .for_account(account)
        .includes(:current_version)
        .find_by(slug: slug)
      )
    end

    def global_scope
      resolve_active_version(
        Strategy.active
        .global
        .includes(:current_version)
        .find_by(slug: slug)
      )
    end

    def resolve_active_version(strategy)
      version = strategy&.current_version
      return unless version&.active?

      version
    end
  end
end
