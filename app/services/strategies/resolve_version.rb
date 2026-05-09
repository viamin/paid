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
      strategy = resolve_strategy
      version = strategy&.current_version
      return unless version&.active?

      version
    end

    private

    attr_reader :slug, :project, :account

    def resolve_strategy
      scoped_candidates.find(&:present?)
    end

    def scoped_candidates
      [
        project_scope,
        account_scope,
        global_scope
      ]
    end

    def project_scope
      return unless project

      Strategy.active
        .for_project(project)
        .includes(:current_version)
        .find_by(slug: slug)
    end

    def account_scope
      return unless account

      Strategy.active
        .for_account(account)
        .includes(:current_version)
        .find_by(slug: slug)
    end

    def global_scope
      Strategy.active
        .global
        .includes(:current_version)
        .find_by(slug: slug)
    end
  end
end
