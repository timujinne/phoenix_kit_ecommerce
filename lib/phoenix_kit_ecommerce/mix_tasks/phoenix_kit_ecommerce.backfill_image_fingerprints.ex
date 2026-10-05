defmodule Mix.Tasks.PhoenixKitEcommerce.BackfillImageFingerprints do
  # Ignore Mix.Task behaviour callback info (unavailable in PLT)
  @dialyzer :no_undefined_callbacks

  @moduledoc """
  Stamps a perceptual fingerprint (`metadata["image_fingerprint"]`) on the
  images this module imported before fingerprints existed, or under an
  older fingerprint version.

  `ImageDownloader.download_and_store/3` reuses a stored picture for its
  re-encoded copies by matching fingerprints. A library imported before
  that has none, so until this has run no stored image is a candidate and
  every copy is fetched and stored again. Run it once after upgrading,
  and again right after any release that changes
  `ImageFingerprint.version/0`, in both cases before the next Shopify
  media sync.

  ## Usage

      mix phoenix_kit_ecommerce.backfill_image_fingerprints

  Reads each image's original from Storage once, checks it has one frame,
  computes its fingerprint and walks every such file in one run. A file that cannot be read
  or fingerprinted is left as it is, logged and counted as failed; running
  the task again retries only what is still missing. It writes nothing but
  that one metadata key.
  """

  use Mix.Task

  alias PhoenixKitEcommerce.Services.ImageDownloader

  @shortdoc "Stamp a perceptual fingerprint on imported images that lack one"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("Fingerprinting imported images…")

    %{fingerprinted: fingerprinted, failed: failed} = ImageDownloader.backfill_fingerprints()

    Mix.shell().info("  fingerprinted: #{fingerprinted}")

    if failed > 0 do
      Mix.shell().error("  failed: #{failed} (see the log for each file)")
    else
      Mix.shell().info("  failed: 0")
    end
  end
end
