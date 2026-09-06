defmodule PhoenixKitEcommerce.Migrations do
  @moduledoc """
  Module-owned migration chain for the shop tables (`phoenix_kit_shop_config`,
  `phoenix_kit_shop_shipping_methods`, `phoenix_kit_shop_categories`,
  `phoenix_kit_shop_products`, `phoenix_kit_shop_product_slugs`,
  `phoenix_kit_shop_category_slugs`, `phoenix_kit_shop_carts`,
  `phoenix_kit_shop_cart_items`, `phoenix_kit_shop_import_configs`,
  `phoenix_kit_shop_import_logs`) plus the two slug-projection functions and
  their triggers.

  ## Ownership situation — read before touching

  All ten tables are core V135(+later) baseline tables; core still creates
  them today. V1 is purely an ADOPTION step (owner decision 2026-09-05: this
  chain adopts every shop table, including `phoenix_kit_shop_products` and
  `phoenix_kit_shop_categories`, so upstream `phoenix_kit_ecommerce` — which
  still owns products for hosts that have not switched to the catalogue —
  stays whole through core's next baseline squash):

    * on existing installs every table is already there (core's baseline),
      the `CREATE TABLE IF NOT EXISTS` finds it, and the only new objects
      are the `CREATE OR REPLACE FUNCTION` bodies (already core-owned,
      unchanged) and the `pke_schema:1` marker;
    * on a hypothetical future install whose core baseline no longer
      creates these tables, the same statements create them —
      shape-identical to core's objects, with core's exact index,
      constraint, function and trigger names.

  This deployment's `shop_products`/`shop_categories`/both slug
  projections are deprecated in favor of `phoenix_kit_catalogue` later
  (Block 3, after the storefront switch) via a host-side
  `COMMENT ON TABLE … 'deprecated …'` — never a DROP, and not part of
  this chain.

  ## V2 — `DROP DEFAULT` on the four `currency` columns

  V1 adopts core's shape verbatim; V2 is the chain's first deliberate
  divergence from it. Core's baseline declares `"currency" character
  varying(3) DEFAULT 'USD'` on `phoenix_kit_shop_carts`,
  `…_cart_items`, `…_products` and `…_shipping_methods`. Dropping the
  Elixir-side `default: "USD"` (PR #31) did not remove that literal — it
  only stopped Ecto from sending a value, which let Postgres substitute
  `'USD'` itself. V2 drops the column defaults so an insert that names no
  currency stores NULL. Existing rows are untouched; `down/1` restores the
  defaults.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker and restores the V2 column
  defaults; it NEVER drops any of the ten tables, the two functions, or
  the two triggers. The tables are
  core-created, and rolling back this module's chain must not destroy
  data — only core's own baseline rollback does that.

  The migrated version is tracked as a `pke_schema:<N>` COMMENT on
  `phoenix_kit_shop_config` (the marker convention `phoenix_kit_billing`,
  `phoenix_kit_entities` and `phoenix_kit_catalogue` also use). A
  marker-less or foreign-comment table reads as version 0 — the
  core-baseline shape before this chain existed.

  Protocol: `phoenix_kit_hello_world` README, "Adopting a table core
  already creates (extraction)".

  Every column name below is double-quoted, unlike the `pg_dump` source
  (which only quotes `"position"`, a reserved word). This is a
  normalization, not drift — the two forms are semantically identical.
  """

  use Ecto.Migration

  @current_version 2
  @marker_prefix "pke_schema:"
  @version_table "phoenix_kit_shop_config"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pke_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version applied in the database, read INSIDE a running
  migration (via `repo()`, same as `up/1`/`down/1`).
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)

    %{rows: rows} = repo().query!(marker_query(), [prefix])

    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pke_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed") — that misleads the operator AND
    # lets the unvalidated string reach interpolated SQL in callers'
    # fallback paths.
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc "Applies every chain version up to `current_version/0` (idempotent)."
  def up(opts \\ []) do
    opts
    |> validated_prefix()
    |> up_statements()
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops any table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The test
  suite scans this for: table/function/trigger names matching core's
  exact names (including the five `*_uuid_idx` core embeds the schema name
  into under a non-public prefix), a representative sample of index and
  constraint names, no statement that can drop or truncate a table (except the scoped,
  pre-existing `DELETE` inside the two adopted slug-projection function
  bodies — core-authored runtime logic, unchanged, not migration-time
  destruction), and that every index/constraint is guarded.
  """
  @spec up_statements(String.t()) :: [String.t()]
  def up_statements(prefix \\ "public") do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    tables(p) ++
      functions(p) ++
      constraints(prefix, p) ++
      triggers(p) ++
      indexes(prefix, p) ++
      v2_drop_currency_defaults(p) ++
      [marker_statement(p, @current_version)]
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping plus the V2 default restore)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    restore = if target < 2, do: v2_restore_currency_defaults(p), else: []

    if target > 0 do
      restore ++ [marker_statement(p, target)]
    else
      restore ++ ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # V2 — the last "USD" literal in the module.
  #
  # PR #31 dropped `default: "USD"` from the four `:currency` fields, but
  # only from the ELIXIR schemas; core's baseline still declares
  # `"currency" character varying(3) DEFAULT 'USD'` on all four columns.
  # Ecto omits an unchanged field from the INSERT, so a `create_product/1`
  # or `create_shipping_method/1` that resolved no default currency wrote
  # `currency = NULL` in the struct it handed back and `'USD'` in the row —
  # the silent literal the PR set out to delete, one layer down, plus a
  # struct that disagreed with its own row.
  #
  # `DROP DEFAULT` touches no existing row: a shop that already stores
  # "USD" keeps storing it (that IS its history), and only inserts that
  # name no currency now land as NULL, which is what "no default currency
  # is configured" honestly means.
  @currency_default_tables ~w(
    phoenix_kit_shop_carts
    phoenix_kit_shop_cart_items
    phoenix_kit_shop_products
    phoenix_kit_shop_shipping_methods
  )

  defp v2_drop_currency_defaults(p) do
    for t <- @currency_default_tables do
      ~s(ALTER TABLE #{p}#{t} ALTER COLUMN "currency" DROP DEFAULT)
    end
  end

  defp v2_restore_currency_defaults(p) do
    for t <- @currency_default_tables do
      ~s(ALTER TABLE #{p}#{t} ALTER COLUMN "currency" SET DEFAULT 'USD'::character varying)
    end
  end

  defp marker_statement(p, version),
    do: "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{version}'"

  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_config (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "key" character varying(255) NOT NULL,
        "value" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_shipping_methods (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "name" character varying(255) NOT NULL,
        "slug" character varying(100) NOT NULL,
        "description" text,
        "price" numeric(12,2) DEFAULT 0 NOT NULL,
        "currency" character varying(3) DEFAULT 'USD'::character varying,
        "free_above_amount" numeric(12,2),
        "min_weight_grams" integer DEFAULT 0,
        "max_weight_grams" integer,
        "min_order_amount" numeric(12,2),
        "max_order_amount" numeric(12,2),
        "countries" jsonb DEFAULT '[]'::jsonb,
        "excluded_countries" jsonb DEFAULT '[]'::jsonb,
        "active" boolean DEFAULT true,
        "position" integer DEFAULT 0,
        "estimated_days_min" integer,
        "estimated_days_max" integer,
        "tracking_supported" boolean DEFAULT false,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_categories (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "position" integer DEFAULT 0,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "option_schema" jsonb DEFAULT '[]'::jsonb,
        "image_uuid" uuid,
        "status" character varying(20) DEFAULT 'active'::character varying,
        "name" jsonb DEFAULT '{}'::jsonb,
        "slug" jsonb DEFAULT '{}'::jsonb,
        "description" jsonb DEFAULT '{}'::jsonb,
        "parent_uuid" uuid,
        "featured_product_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_products (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "status" character varying(20) DEFAULT 'draft'::character varying,
        "product_type" character varying(20) DEFAULT 'physical'::character varying,
        "vendor" character varying(255),
        "tags" jsonb DEFAULT '[]'::jsonb,
        "price" numeric(12,2) NOT NULL,
        "compare_at_price" numeric(12,2),
        "cost_per_item" numeric(12,2),
        "currency" character varying(3) DEFAULT 'USD'::character varying,
        "taxable" boolean DEFAULT true,
        "weight_grams" integer DEFAULT 0,
        "requires_shipping" boolean DEFAULT true,
        "has_variants" boolean DEFAULT false,
        "option_names" jsonb DEFAULT '[]'::jsonb,
        "images" jsonb DEFAULT '[]'::jsonb,
        "featured_image" text,
        "file_uuid" uuid,
        "download_limit" integer,
        "download_expiry_days" integer,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "made_to_order" boolean DEFAULT false,
        "featured_image_uuid" uuid,
        "image_uuids" uuid[] DEFAULT '{}'::uuid[],
        "title" jsonb DEFAULT '{}'::jsonb,
        "slug" jsonb DEFAULT '{}'::jsonb,
        "description" jsonb DEFAULT '{}'::jsonb,
        "body_html" jsonb DEFAULT '{}'::jsonb,
        "seo_title" jsonb DEFAULT '{}'::jsonb,
        "seo_description" jsonb DEFAULT '{}'::jsonb,
        "created_by_uuid" uuid,
        "category_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_product_slugs (
        "lang" text NOT NULL,
        "value" text NOT NULL,
        "product_uuid" uuid NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_category_slugs (
        "lang" text NOT NULL,
        "value" text NOT NULL,
        "category_uuid" uuid NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_carts (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "session_id" character varying(64),
        "status" character varying(20) DEFAULT 'active'::character varying,
        "shipping_country" character varying(2),
        "subtotal" numeric(12,2) DEFAULT 0,
        "shipping_amount" numeric(12,2) DEFAULT 0,
        "tax_amount" numeric(12,2) DEFAULT 0,
        "discount_amount" numeric(12,2) DEFAULT 0,
        "total" numeric(12,2) DEFAULT 0,
        "currency" character varying(3) DEFAULT 'USD'::character varying,
        "discount_code" character varying(100),
        "total_weight_grams" integer DEFAULT 0,
        "items_count" integer DEFAULT 0,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "expires_at" timestamp with time zone,
        "converted_at" timestamp with time zone,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "user_uuid" uuid,
        "shipping_method_uuid" uuid,
        "merged_into_cart_uuid" uuid,
        "payment_option_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_cart_items (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "product_title" character varying(255) NOT NULL,
        "product_slug" character varying(255),
        "product_sku" character varying(100),
        "product_image" character varying(500),
        "unit_price" numeric(12,2) NOT NULL,
        "compare_at_price" numeric(12,2),
        "currency" character varying(3) DEFAULT 'USD'::character varying,
        "quantity" integer DEFAULT 1 NOT NULL,
        "line_total" numeric(12,2) NOT NULL,
        "weight_grams" integer DEFAULT 0,
        "taxable" boolean DEFAULT true,
        "variant_options" jsonb DEFAULT '{}'::jsonb,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "selected_specs" jsonb DEFAULT '{}'::jsonb,
        "cart_uuid" uuid NOT NULL,
        "product_uuid" uuid,
        "variant_uuid" uuid,
        CONSTRAINT phoenix_kit_shop_cart_items_quantity_positive CHECK ((quantity > 0))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_import_configs (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "name" character varying(255) NOT NULL,
        "include_keywords" text[] DEFAULT '{}'::text[],
        "exclude_keywords" text[] DEFAULT '{}'::text[],
        "exclude_phrases" text[] DEFAULT '{}'::text[],
        "skip_filter" boolean DEFAULT false,
        "category_rules" jsonb DEFAULT '[]'::jsonb,
        "default_category_slug" character varying(255),
        "required_columns" text[] DEFAULT ARRAY['Handle'::text, 'Title'::text, 'Variant Price'::text],
        "is_default" boolean DEFAULT false,
        "active" boolean DEFAULT true,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "option_mappings" jsonb DEFAULT '[]'::jsonb,
        "download_images" boolean DEFAULT false
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_shop_import_logs (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "filename" character varying(255) NOT NULL,
        "file_path" character varying(1024),
        "status" character varying(50) DEFAULT 'pending'::character varying,
        "total_rows" integer DEFAULT 0,
        "processed_rows" integer DEFAULT 0,
        "imported_count" integer DEFAULT 0,
        "updated_count" integer DEFAULT 0,
        "skipped_count" integer DEFAULT 0,
        "error_count" integer DEFAULT 0,
        "options" jsonb DEFAULT '{}'::jsonb,
        "error_details" jsonb DEFAULT '[]'::jsonb,
        "started_at" timestamp with time zone,
        "completed_at" timestamp with time zone,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "user_uuid" uuid,
        "product_uuids" uuid[] DEFAULT '{}'::uuid[]
      )
      """
    ]
  end

  # The two slug-projection functions this chain adopts (core-authored,
  # unchanged) — `CREATE OR REPLACE FUNCTION` is idempotent by definition.
  # The legacy `extract_primary_slug()` function is NOT adopted (core
  # keeps it for its own `down/1`).
  defp functions(p) do
    [
      """
      CREATE OR REPLACE FUNCTION #{p}sync_shop_category_slugs()
       RETURNS trigger
       LANGUAGE plpgsql
      AS $function$
      BEGIN
        DELETE FROM #{p}phoenix_kit_shop_category_slugs WHERE category_uuid = NEW.uuid;

        INSERT INTO #{p}phoenix_kit_shop_category_slugs (lang, value, category_uuid)
        SELECT DISTINCT lower(split_part(e.key, '-', 1)), e.value, NEW.uuid
          FROM jsonb_each_text(COALESCE(NEW.slug, '{}'::jsonb)) e
         WHERE e.value <> '';

        RETURN NEW;
      END $function$
      """,
      """
      CREATE OR REPLACE FUNCTION #{p}sync_shop_product_slugs()
       RETURNS trigger
       LANGUAGE plpgsql
      AS $function$
      BEGIN
        DELETE FROM #{p}phoenix_kit_shop_product_slugs WHERE product_uuid = NEW.uuid;

        INSERT INTO #{p}phoenix_kit_shop_product_slugs (lang, value, product_uuid)
        SELECT DISTINCT lower(split_part(e.key, '-', 1)), e.value, NEW.uuid
          FROM jsonb_each_text(COALESCE(NEW.slug, '{}'::jsonb)) e
         WHERE e.value <> '';

        RETURN NEW;
      END $function$
      """
    ]
  end

  defp constraints(prefix, p) do
    [
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_cart_items",
        "phoenix_kit_shop_cart_items_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_carts",
        "phoenix_kit_shop_carts_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_categories",
        "phoenix_kit_shop_categories_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_category_slugs",
        "phoenix_kit_shop_category_slugs_pkey",
        "PRIMARY KEY (lang, value)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_config",
        "phoenix_kit_shop_config_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_import_configs",
        "phoenix_kit_shop_import_configs_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_import_logs",
        "phoenix_kit_shop_import_logs_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_product_slugs",
        "phoenix_kit_shop_product_slugs_pkey",
        "PRIMARY KEY (lang, value)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_products",
        "phoenix_kit_shop_products_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_shipping_methods",
        "phoenix_kit_shop_shipping_methods_pkey",
        "PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_shipping_methods",
        "phoenix_kit_shop_shipping_methods_slug_unique",
        "UNIQUE (slug)"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_cart_items",
        "fk_shop_cart_items_cart_uuid",
        "FOREIGN KEY (cart_uuid) REFERENCES #{p}phoenix_kit_shop_carts(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_cart_items",
        "fk_shop_cart_items_product_uuid",
        "FOREIGN KEY (product_uuid) REFERENCES #{p}phoenix_kit_shop_products(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_carts",
        "fk_shop_carts_payment_option_uuid",
        "FOREIGN KEY (payment_option_uuid) REFERENCES #{p}phoenix_kit_payment_options(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_carts",
        "fk_shop_carts_shipping_method_uuid",
        "FOREIGN KEY (shipping_method_uuid) REFERENCES #{p}phoenix_kit_shop_shipping_methods(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_carts",
        "fk_shop_carts_user_uuid",
        "FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_categories",
        "fk_shop_categories_featured_product_uuid",
        "FOREIGN KEY (featured_product_uuid) REFERENCES #{p}phoenix_kit_shop_products(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_categories",
        "fk_shop_categories_parent_uuid",
        "FOREIGN KEY (parent_uuid) REFERENCES #{p}phoenix_kit_shop_categories(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_import_logs",
        "fk_shop_import_logs_user_uuid",
        "FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_products",
        "fk_shop_products_category_uuid",
        "FOREIGN KEY (category_uuid) REFERENCES #{p}phoenix_kit_shop_categories(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_products",
        "fk_shop_products_created_by_uuid",
        "FOREIGN KEY (created_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_category_slugs",
        "phoenix_kit_shop_category_slugs_category_uuid_fkey",
        "FOREIGN KEY (category_uuid) REFERENCES #{p}phoenix_kit_shop_categories(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        p,
        "phoenix_kit_shop_product_slugs",
        "phoenix_kit_shop_product_slugs_product_uuid_fkey",
        "FOREIGN KEY (product_uuid) REFERENCES #{p}phoenix_kit_shop_products(uuid) ON DELETE CASCADE"
      )
    ]
  end

  defp guarded_constraint(prefix, p, table, name, definition) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}#{table} ADD CONSTRAINT #{name} #{definition};
      END IF;
    END
    $$
    """
  end

  # Postgres has no `CREATE TRIGGER IF NOT EXISTS`; each trigger is wrapped
  # in a `pg_trigger` existence guard instead.
  defp triggers(p) do
    [
      guarded_trigger(
        p,
        "phoenix_kit_shop_categories",
        "trg_shop_category_slugs",
        "AFTER INSERT OR UPDATE OF slug ON #{p}phoenix_kit_shop_categories FOR EACH ROW EXECUTE FUNCTION #{p}sync_shop_category_slugs()"
      ),
      guarded_trigger(
        p,
        "phoenix_kit_shop_products",
        "trg_shop_product_slugs",
        "AFTER INSERT OR UPDATE OF slug ON #{p}phoenix_kit_shop_products FOR EACH ROW EXECUTE FUNCTION #{p}sync_shop_product_slugs()"
      )
    ]
  end

  defp guarded_trigger(p, table, name, definition) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{name}' AND tgrelid = '#{p}#{table}'::regclass) THEN
        CREATE TRIGGER #{name} #{definition};
      END IF;
    END
    $$
    """
  end

  # Core embeds the schema name in exactly five of these index names under a
  # non-public prefix (`pn` in core's V135, `__PK_NAME_EXEMPT__` in its
  # expected-schema manifest): the five `*_uuid_idx` on the core-created shop
  # tables. Mirroring that is the whole point of an adoptive chain — a bare
  # name there does NOT find core's `<prefix>_..._uuid_idx`, so
  # `CREATE UNIQUE INDEX IF NOT EXISTS` builds a SECOND, redundant unique
  # index on every prefixed install and leaves the schema drifted from the
  # manifest. Every other index core creates on these tables is named the
  # same in every schema.
  defp indexes(prefix, p) do
    pn = if prefix == "public", do: "", else: "#{prefix}_"

    [
      idx(
        p,
        "idx_shop_cart_items_selected_specs",
        "phoenix_kit_shop_cart_items",
        "gin (selected_specs)"
      ),
      idx(
        p,
        "idx_shop_carts_session",
        "phoenix_kit_shop_carts",
        "btree (session_id) WHERE (session_id IS NOT NULL)"
      ),
      idx(p, "idx_shop_carts_status", "phoenix_kit_shop_carts", "btree (status)"),
      idx(
        p,
        "idx_shop_categories_position",
        "phoenix_kit_shop_categories",
        "btree (\"position\")"
      ),
      idx(
        p,
        "idx_shop_categories_status",
        "phoenix_kit_shop_categories",
        "btree (status)"
      ),
      unique_idx(p, "idx_shop_config_key", "phoenix_kit_shop_config", "btree (key)"),
      unique_idx(p, "idx_shop_config_uuid", "phoenix_kit_shop_config", "btree (uuid)"),
      idx(
        p,
        "idx_shop_import_configs_is_default",
        "phoenix_kit_shop_import_configs",
        "btree (is_default) WHERE (is_default = true)"
      ),
      unique_idx(
        p,
        "idx_shop_import_configs_name",
        "phoenix_kit_shop_import_configs",
        "btree (name)"
      ),
      unique_idx(
        p,
        "idx_shop_import_configs_uuid",
        "phoenix_kit_shop_import_configs",
        "btree (uuid)"
      ),
      idx(
        p,
        "idx_shop_import_logs_inserted_at",
        "phoenix_kit_shop_import_logs",
        "btree (inserted_at DESC)"
      ),
      idx(
        p,
        "idx_shop_import_logs_status",
        "phoenix_kit_shop_import_logs",
        "btree (status)"
      ),
      unique_idx(p, "idx_shop_import_logs_uuid", "phoenix_kit_shop_import_logs", "btree (uuid)"),
      idx(p, "idx_shop_products_status", "phoenix_kit_shop_products", "btree (status)"),
      idx(p, "idx_shop_products_tags", "phoenix_kit_shop_products", "gin (tags)"),
      idx(
        p,
        "idx_shop_products_type",
        "phoenix_kit_shop_products",
        "btree (product_type)"
      ),
      idx(
        p,
        "idx_shop_shipping_active",
        "phoenix_kit_shop_shipping_methods",
        "btree (active)"
      ),
      idx(
        p,
        "idx_shop_shipping_position",
        "phoenix_kit_shop_shipping_methods",
        "btree (\"position\")"
      ),
      idx(
        p,
        "phoenix_kit_shop_cart_items_cart_uuid_idx",
        "phoenix_kit_shop_cart_items",
        "btree (cart_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_cart_items_product_uuid_idx",
        "phoenix_kit_shop_cart_items",
        "btree (product_uuid)"
      ),
      exempt_unique_idx(
        pn,
        p,
        "phoenix_kit_shop_cart_items_uuid_idx",
        "phoenix_kit_shop_cart_items",
        "btree (uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_cart_items_variant_uuid_idx",
        "phoenix_kit_shop_cart_items",
        "btree (variant_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_carts_merged_into_cart_uuid_idx",
        "phoenix_kit_shop_carts",
        "btree (merged_into_cart_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_carts_payment_option_uuid_idx",
        "phoenix_kit_shop_carts",
        "btree (payment_option_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_carts_shipping_method_uuid_idx",
        "phoenix_kit_shop_carts",
        "btree (shipping_method_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_carts_user_uuid_idx",
        "phoenix_kit_shop_carts",
        "btree (user_uuid)"
      ),
      exempt_unique_idx(
        pn,
        p,
        "phoenix_kit_shop_carts_uuid_idx",
        "phoenix_kit_shop_carts",
        "btree (uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_categories_featured_product_uuid_idx",
        "phoenix_kit_shop_categories",
        "btree (featured_product_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_categories_parent_uuid_idx",
        "phoenix_kit_shop_categories",
        "btree (parent_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_categories_slug_gin_idx",
        "phoenix_kit_shop_categories",
        "gin (slug)"
      ),
      exempt_unique_idx(
        pn,
        p,
        "phoenix_kit_shop_categories_uuid_idx",
        "phoenix_kit_shop_categories",
        "btree (uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_category_slugs_category_uuid_idx",
        "phoenix_kit_shop_category_slugs",
        "btree (category_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_import_logs_user_uuid_idx",
        "phoenix_kit_shop_import_logs",
        "btree (user_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_product_slugs_product_uuid_idx",
        "phoenix_kit_shop_product_slugs",
        "btree (product_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_products_category_uuid_idx",
        "phoenix_kit_shop_products",
        "btree (category_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_products_created_by_uuid_idx",
        "phoenix_kit_shop_products",
        "btree (created_by_uuid)"
      ),
      idx(
        p,
        "phoenix_kit_shop_products_slug_gin_idx",
        "phoenix_kit_shop_products",
        "gin (slug)"
      ),
      exempt_unique_idx(
        pn,
        p,
        "phoenix_kit_shop_products_uuid_idx",
        "phoenix_kit_shop_products",
        "btree (uuid)"
      ),
      exempt_unique_idx(
        pn,
        p,
        "phoenix_kit_shop_shipping_methods_uuid_idx",
        "phoenix_kit_shop_shipping_methods",
        "btree (uuid)"
      )
    ]
  end

  defp idx(p, name, table, using), do: build_index(p, "", name, table, using)

  defp unique_idx(p, name, table, using), do: build_index(p, "UNIQUE ", name, table, using)

  defp exempt_unique_idx(pn, p, name, table, using),
    do: build_index(p, "UNIQUE ", pn <> name, table, using)

  defp build_index(p, unique, name, table, using),
    do: "CREATE #{unique}INDEX IF NOT EXISTS #{name} ON #{p}#{table} USING #{using}"

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
