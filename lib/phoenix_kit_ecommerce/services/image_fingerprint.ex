defmodule PhoenixKitEcommerce.Services.ImageFingerprint do
  @moduledoc """
  A perceptual fingerprint of an image: what lets `ImageDownloader` tell a
  re-encoded, re-saved or downscaled copy of a picture it already stored
  apart from a genuinely different picture.

  Byte checksums cannot do that. A Shopify store that was filled from Etsy
  holds the same banner ("Thank you for your support", a filament color
  chart, a care card) as a separate file on every listing — each with its
  own CDN URL and bytes that differ by a few dozen bytes — so an import
  keyed on URL or checksum downloads every copy. One live library held 389
  files for 13 such pictures.

  ## The fingerprint

  One ImageMagick call turns the image upright (EXIF orientation),
  flattens any transparency onto white — a shape drawn only in the alpha
  channel is the picture, and its RGB underneath is meaningless — and
  scales it to 17×16 RGB. From those pixels:

    * a 256-bit difference hash (dHash) of the luma: for each of the 16
      rows, whether each pixel is darker than its right-hand neighbor —
      the picture's structure, insensitive to re-encoding and scale;
    * a 4×4 grid of mean RGB values (48 bytes) — its colors, which the
      luma hash cannot see (the same room with a pink and with a grey
      wall hashes alike).

  Stored as `"v2:<64 hex hash>:<96 hex colors>"`.

  ## The match — two steps

  1. **Fingerprints** (`match/2`): the hashes differ in at most 8 bits,
     the colors by at most 4 on average and by at most 12 in any single
     cell. Cheap, and stored, so it picks candidates out of a whole
     library. The single-cell bound keeps two color variants of one
     product photo apart, the 256-bit hash two objects photographed on
     the same plain background (an 8×8 hash with no color check joined
     both).
  2. **The pictures themselves** (`same_picture?/2`): both fitted into
     256×256 grey with white padding, preserving their aspect ratios,
     the absolute difference averaged over 5×5 pixels; the
     largest of those local averages must stay within 24 (of 255). A
     fingerprint cannot see a line or a label added to an otherwise
     identical picture; this sees one that survives scaling to 256 px —
     a detail thinner than about 0.2% of the image's side (a 2 px rule on
     a 2000 px picture) can stay under the bound.

  Measured on a live library of 3,121 images. Step 1 joined 376 redundant
  banner copies and 139 groups of duplicated product photos — and also 24
  copies of a measuring chart that carries an extra "Chin width" line
  into the version without it (fingerprints 2 bits apart). The original
  step 2, which stretched both images to a square, put
  every true copy at or below 6.8, the two chart versions at 75 and a
  cropped re-save of a chart at 106. (Those figures are for that library:
  a half-size JPEG re-save measured 7.2 elsewhere, a GIF frame 11.)

  ImageMagick runs with core's resource limits and with its decoder
  pinned to the format the file's bytes sniff as
  (`PhoenixKit.Modules.Storage.ImageProcessor`), the same envelope every
  other ImageMagick call in PhoenixKit runs in.

  Multi-frame images are excluded from perceptual reuse. Their first
  frames can agree while the rest of the animation differs; byte-based
  reuse in `ImageDownloader` remains available for identical files.
  """

  require Logger

  alias PhoenixKit.Modules.Storage.ImageProcessor

  @version "v2"
  @width 17
  @height 16
  @raw_size @width * @height * 3

  @max_hash_bits 8
  @max_mean_color 4
  @max_cell_color 12

  @detail_size 256
  @max_local_difference 24

  @typedoc "`\"v2:<64 hex>:<96 hex>\"`"
  @type t :: String.t()

  @doc """
  The version prefix of the fingerprints this module computes and
  compares. A fingerprint of another version never matches; stored ones
  are re-stamped by `ImageDownloader.backfill_fingerprints/0`.

  Run that backfill right after deploying a new version and before the
  next media sync: until it has run, no stored image is a candidate, so
  every copy is fetched again — including the URL of a copy someone
  trashed, whose bytes core's own dedup then hands back and the download
  restores.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Computes the fingerprint of the image at `path`.

  Returns `{:error, reason}` for anything ImageMagick cannot read as a
  raster image (SVG included — the decoder is pinned to the sniffed
  format), for multi-frame images (`:multiple_frames`), and when
  ImageMagick is not installed.
  """
  @spec compute(Path.t()) :: {:ok, t()} | {:error, term()}
  def compute(path) when is_binary(path) do
    with {:ok, input} <- single_frame_input(path),
         {:ok, raw} <- scale(input) do
      {:ok, encode(raw)}
    end
  rescue
    # `System.cmd/3` raises when the executable is missing altogether.
    e -> {:error, {:fingerprint_failed, Exception.message(e)}}
  end

  # Inspect all frames through the pinned decoder, without decoding the
  # full pixels. Selecting [0] first would hide an animation's other frames.
  defp single_frame_input(path) do
    with {:ok, input} <- ImageProcessor.pinned_input(path) do
      args = ImageProcessor.limit_args() ++ ["-quiet", "-ping", input, "-format", "%n", "info:"]

      case System.cmd("convert", args, stderr_to_stdout: false) do
        {"1", 0} -> {:ok, input}
        {_out, 0} -> {:error, :multiple_frames}
        {_out, code} -> {:error, {:convert_failed, code}}
      end
    end
  end

  defp scale(input) do
    args =
      ImageProcessor.limit_args() ++
        [
          "-quiet",
          input,
          "-auto-orient",
          "-background",
          "white",
          "-alpha",
          "remove",
          "-alpha",
          "off",
          "-colorspace",
          "sRGB",
          "-resize",
          "#{@width}x#{@height}!",
          "-depth",
          "8",
          "rgb:-"
        ]

    case System.cmd("convert", args, stderr_to_stdout: false) do
      {raw, 0} when byte_size(raw) == @raw_size -> {:ok, raw}
      {_out, 0} -> {:error, :unexpected_output}
      {_out, code} -> {:error, {:convert_failed, code}}
    end
  end

  defp encode(raw) do
    rows =
      for <<row::binary-size(@width * 3) <- raw>> do
        for(<<r, g, b <- row>>, do: {r, g, b}) |> List.to_tuple()
      end
      |> List.to_tuple()

    hash =
      for y <- 0..(@height - 1), x <- 0..(@width - 2), into: <<>> do
        left = luma(pixel(rows, x, y))
        right = luma(pixel(rows, x + 1, y))
        if left < right, do: <<1::1>>, else: <<0::1>>
      end

    colors =
      for by <- 0..3, bx <- 0..3, channel <- 0..2, into: <<>> do
        sum =
          for dy <- 0..3, dx <- 0..3, reduce: 0 do
            acc -> acc + elem(pixel(rows, bx * 4 + dx, by * 4 + dy), channel)
          end

        <<div(sum, 16)>>
      end

    Enum.join(
      [@version, Base.encode16(hash, case: :lower), Base.encode16(colors, case: :lower)],
      ":"
    )
  end

  defp pixel(rows, x, y), do: rows |> elem(y) |> elem(x)

  # Rec. 601 luma, in integers.
  defp luma({r, g, b}), do: div(299 * r + 587 * g + 114 * b, 1000)

  @doc """
  The distances between two fingerprints: differing hash bits, the mean
  and the largest per-cell color difference. `:error` when either is not
  a well-formed fingerprint of this version.
  """
  @spec compare(term(), term()) ::
          {:ok, %{bits: non_neg_integer(), mean_color: float(), max_color: non_neg_integer()}}
          | :error
  def compare(a, b) do
    with {:ok, {hash_a, colors_a}} <- decode(a),
         {:ok, {hash_b, colors_b}} <- decode(b) do
      bits = for <<bit::1 <- :crypto.exor(hash_a, hash_b)>>, reduce: 0, do: (acc -> acc + bit)

      diffs =
        Enum.zip_with(:binary.bin_to_list(colors_a), :binary.bin_to_list(colors_b), &abs(&1 - &2))

      {:ok,
       %{bits: bits, mean_color: Enum.sum(diffs) / length(diffs), max_color: Enum.max(diffs)}}
    end
  end

  @doc """
  The distances (as `compare/2`) when two fingerprints are the same
  picture — see the module doc for the bounds and the measurement behind
  them — `:nomatch` otherwise. Anything malformed, or of another version,
  never matches.
  """
  @spec match(term(), term()) ::
          {:ok, %{bits: non_neg_integer(), mean_color: float(), max_color: non_neg_integer()}}
          | :nomatch
  def match(a, b) do
    case compare(a, b) do
      {:ok, %{bits: bits, mean_color: mean, max_color: max} = distances}
      when bits <= @max_hash_bits and mean <= @max_mean_color and max <= @max_cell_color ->
        {:ok, distances}

      _ ->
        :nomatch
    end
  end

  @doc "Whether two fingerprints are the same picture (`match/2` as a boolean)."
  @spec match?(term(), term()) :: boolean()
  def match?(a, b), do: match(a, b) != :nomatch

  @doc """
  Step 2 of the match (see the module doc): whether the images at
  `path_a` and `path_b` are the same picture down to a thin line or a
  small label. Meant for a pair whose fingerprints already `match/2` —
  it checks the frame counts, then compares the full images. `false`
  when either cannot be read or contains multiple frames.
  """
  @spec same_picture?(Path.t(), Path.t()) :: boolean()
  def same_picture?(path_a, path_b) do
    case local_difference(path_a, path_b) do
      {:ok, difference} -> difference <= @max_local_difference
      {:error, _reason} -> false
    end
  end

  @doc """
  The largest 5×5 local mean of the absolute difference between the two
  images fitted into 256×256 grey with white padding, in 0..255 — what `same_picture?/2`
  bounds.
  """
  @spec local_difference(Path.t(), Path.t()) :: {:ok, float()} | {:error, term()}
  def local_difference(path_a, path_b) when is_binary(path_a) and is_binary(path_b) do
    with {:ok, input_a} <- single_frame_input(path_a),
         {:ok, input_b} <- single_frame_input(path_b) do
      args =
        ImageProcessor.limit_args() ++
          [
            "-quiet",
            input_a,
            input_b,
            "-auto-orient",
            "-background",
            "white",
            "-alpha",
            "remove",
            "-alpha",
            "off",
            "-colorspace",
            "Gray",
            "-resize",
            "#{@detail_size}x#{@detail_size}",
            "-gravity",
            "center",
            "-extent",
            "#{@detail_size}x#{@detail_size}",
            "-compose",
            "difference",
            "-composite",
            "-statistic",
            "Mean",
            "5x5",
            "-format",
            "%[fx:maxima*255]",
            "info:"
          ]

      run_difference(args)
    end
  rescue
    e -> {:error, {:compare_failed, Exception.message(e)}}
  end

  defp run_difference(args) do
    case System.cmd("convert", args, stderr_to_stdout: false) do
      {out, 0} -> parse_difference(out)
      {_out, code} -> {:error, {:convert_failed, code}}
    end
  end

  defp parse_difference(out) do
    case Float.parse(String.trim(out)) do
      {difference, ""} -> {:ok, difference}
      _ -> {:error, :unexpected_output}
    end
  end

  defp decode(@version <> ":" <> rest) do
    with [hash_hex, colors_hex] <- String.split(rest, ":"),
         {:ok, <<_::256>> = hash} <- Base.decode16(hash_hex, case: :mixed),
         {:ok, <<_::384>> = colors} <- Base.decode16(colors_hex, case: :mixed) do
      {:ok, {hash, colors}}
    else
      _ -> :error
    end
  end

  defp decode(_other), do: :error
end
