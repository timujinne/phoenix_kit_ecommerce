defmodule Oban.Migrations.Postgres.V09 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix, quoted_prefix: quoted}) do
    alter table(:oban_jobs, prefix: prefix) do
      add_if_not_exists(:meta, :map, default: %{})
      add_if_not_exists(:cancelled_at, :utc_datetime_usec)
    end

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_enum
        WHERE enumlabel = 'cancelled'
        AND enumtypid = '#{quoted}.oban_job_state'::regtype
      ) THEN
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

    create_if_not_exists index(:oban_jobs, [:state, :queue, :priority, :scheduled_at, :id],
                           prefix: prefix
                         )
  end

  def down(%{prefix: prefix, quoted_prefix: quoted}) do
    alter table(:oban_jobs, prefix: prefix) do
      remove_if_exists(:meta, :map)
      remove_if_exists(:cancelled_at, :utc_datetime_usec)
    end

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_enum
        WHERE enumlabel = 'cancelled'
        AND enumtypid = '#{quoted}.oban_job_state'::regtype
      ) THEN
        UPDATE #{quoted}.oban_jobs SET state = 'discarded' WHERE state = 'cancelled';

        ALTER TYPE #{quoted}.oban_job_state RENAME TO oban_job_state_old;

        CREATE TYPE #{quoted}.oban_job_state AS ENUM (
          'available',
          'scheduled',
          'executing',
          'retryable',
          'completed',
          'discarded'
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
