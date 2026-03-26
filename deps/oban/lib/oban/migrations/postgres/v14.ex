defmodule Oban.Migrations.Postgres.V14 do
  @moduledoc false

  use Ecto.Migration

  def up(%{quoted_prefix: quoted}) do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_enum
        WHERE enumlabel = 'suspended'
        AND enumtypid = '#{quoted}.oban_job_state'::regtype
      ) THEN
        ALTER TYPE #{quoted}.oban_job_state RENAME TO oban_job_state_old;

        CREATE TYPE #{quoted}.oban_job_state AS ENUM (
          'available',
          'suspended',
          'scheduled',
          'executing',
          'retryable',
          'completed',
          'discarded',
          'cancelled'
        );

        ALTER TABLE #{quoted}.oban_jobs RENAME COLUMN state TO _state;

        ALTER TABLE #{quoted}.oban_jobs
          ADD state #{quoted}.oban_job_state NOT NULL DEFAULT 'available';

        UPDATE #{quoted}.oban_jobs SET state = _state::text::#{quoted}.oban_job_state;

        ALTER TABLE #{quoted}.oban_jobs DROP COLUMN _state;

        DROP TYPE #{quoted}.oban_job_state_old;
      END IF;
    END$$;
    """
  end

  def down(%{quoted_prefix: quoted}) do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_enum
        WHERE enumlabel = 'suspended'
        AND enumtypid = '#{quoted}.oban_job_state'::regtype
      ) THEN
        UPDATE #{quoted}.oban_jobs SET state = 'scheduled' WHERE state = 'suspended';

        ALTER TYPE #{quoted}.oban_job_state RENAME TO oban_job_state_old;

        CREATE TYPE #{quoted}.oban_job_state AS ENUM (
          'available',
          'scheduled',
          'executing',
          'retryable',
          'completed',
          'discarded',
          'cancelled'
        );

        ALTER TABLE #{quoted}.oban_jobs RENAME COLUMN state TO _state;

        ALTER TABLE #{quoted}.oban_jobs
          ADD state #{quoted}.oban_job_state NOT NULL DEFAULT 'available';

        UPDATE #{quoted}.oban_jobs SET state = _state::text::#{quoted}.oban_job_state;

        ALTER TABLE #{quoted}.oban_jobs DROP COLUMN _state;

        DROP TYPE #{quoted}.oban_job_state_old;
      END IF;
    END$$;
    """
  end
end
