# frozen_string_literal: true

require "openssl"

module Containers
  # Keeps the service's bootstrap identity out of an agent's application URL.
  # @spec CONTAINER-RUNTIME-052 POSTGRESQL-PERSISTENCE-006
  class PostgresApplicationRole
    def self.credentials_for(service_container, database_name)
      identity = "paid-postgres-application-v1:#{service_container.id}:#{database_name}"
      key = Rails.application.secret_key_base
      {
        user: "paid_app_#{OpenSSL::HMAC.hexdigest("SHA256", key, "role:#{identity}").first(24)}",
        password: OpenSSL::HMAC.hexdigest("SHA256", key, "password:#{identity}")
      }
    end

    def self.provision!(service_container:, database_name:, backend:, container:, admin_user:, admin_database:)
      credentials = credentials_for(service_container, database_name)
      raise ServiceProvisioner::DatabaseError, "PostgreSQL application and bootstrap roles must differ" if credentials[:user] == admin_user

      role = identifier(credentials.fetch(:user))
      sql = <<~SQL
        DO $paid_role$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{literal(credentials.fetch(:user))}) THEN
            CREATE ROLE #{role} LOGIN;
          END IF;
        END
        $paid_role$;
        ALTER ROLE #{role} WITH LOGIN NOSUPERUSER NOBYPASSRLS CREATEDB CREATEROLE PASSWORD #{literal(credentials.fetch(:password))};
      SQL
      _stdout, _stderr, status = backend.exec_in_container(container,
        [ "psql", "-v", "ON_ERROR_STOP=1", "-U", admin_user, "-d", admin_database, "-c", sql ])
      return credentials if status == 0

      # PostgreSQL errors can echo the SQL, including the password.
      raise ServiceProvisioner::DatabaseError, "Failed to provision PostgreSQL application role (exit #{status})"
    rescue Docker::Error::DockerError, Excon::Error
      raise ServiceProvisioner::DatabaseError, "PostgreSQL application role transport failed"
    end

    def self.identifier(value) = %("#{value.to_s.gsub('"', '""')}")
    def self.literal(value) = "'#{value.to_s.gsub("'", "''")}'"
    private_class_method :identifier, :literal
  end
end
