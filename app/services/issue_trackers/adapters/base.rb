# frozen_string_literal: true

module IssueTrackers
  module Adapters
    class Base
      attr_reader :tracker_configuration

      def initialize(tracker_configuration)
        @tracker_configuration = tracker_configuration
      end

      def list_issues(filters: {})
        raise NotImplementedError, "#{self.class}#list_issues"
      end

      def get_issue(external_id:)
        raise NotImplementedError, "#{self.class}#get_issue"
      end

      def add_comment(external_id:, body:)
        raise NotImplementedError, "#{self.class}#add_comment"
      end

      def update_status(external_id:, status:)
        raise NotImplementedError, "#{self.class}#update_status"
      end

      def link_pr(external_id:, pr_url:, pr_title:)
        raise NotImplementedError, "#{self.class}#link_pr"
      end

      def validate_connection!
        raise NotImplementedError, "#{self.class}#validate_connection!"
      end

      private

      def base_url
        tracker_configuration.base_url
      end

      def credential
        tracker_configuration.integration_credential
      end

      def project_mapping
        tracker_configuration.project_mapping || {}
      end
    end
  end
end
