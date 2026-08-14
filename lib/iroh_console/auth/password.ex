defmodule IrohConsole.Auth.Password do
  @moduledoc """
  A shared password, configured on the device.

  The simplest adapter that is still a real check: no authenticator app, no
  clock, no issuer. Reasonable for a small deployment or a development device.

  ## Configuration

      auth: {IrohConsole.Auth.Password, password: "…"}
      auth: {IrohConsole.Auth.Password, password_file: "/data/iroh_console/password"}

    * `:password` — the password itself
    * `:password_file` — a file containing it. Trailing whitespace is stripped,
      so a file written with `echo` works.

  Prefer `:password_file` on a device. A password in `config/*.exs` is compiled
  into the release, which means it is in your repository and in every build
  artefact that has ever shipped.

  ## How it compares to TOTP

  Weaker, in one specific way: it does not rotate. `IrohConsole.Auth.TOTP` limits
  a captured code to one period and refuses to accept it twice; a password stays
  valid until someone changes it on the device, which on a fleet means a firmware
  update or a config push.

  Both share the deeper problem — the device stores the thing that verifies the
  credential, so extracting firmware from one device yields access to it, and to
  every device sharing that value. Use a distinct password per device, and treat
  it as you would an SSH private key.

  An adapter where the device holds only a *public* key avoids that entirely and
  is the better answer for a fleet; this is the answer for getting started.

  ## What protects against guessing

  Nothing in this adapter. One connection buys one attempt, so the practical rate
  is bounded by connection setup and by `:max_sessions` on the server — enough to
  make online guessing slow, nowhere near enough to make a short password safe.
  Use a long random one; `IrohConsole.Auth.Password.generate/0` produces one.

  The password crosses the stream to be checked. That stream is encrypted end to
  end by iroh and the peer's identity is already proven, so this is comparable to
  password authentication over SSH — but it does mean the device sees the
  plaintext, unlike a scheme that only ever sees a signature.
  """

  @behaviour IrohConsole.Auth

  require Logger

  # Below this, online guessing stops being merely slow.
  @short_password 12

  @impl true
  def challenge(_context), do: {:ok, IrohConsole.Auth.nonce()}

  @impl true
  def verify(context, _challenge, response) do
    with {:ok, password} <- password(Map.get(context, :opts, [])) do
      if IrohConsole.Auth.secure_compare(to_string(response), password) do
        :ok
      else
        {:error, :wrong_password}
      end
    end
  end

  @doc """
  A random password, for when there is no reason to choose a memorable one.

  32 characters of base32, roughly 160 bits.
  """
  @spec generate() :: String.t()
  def generate, do: 20 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false)

  defp password(opts) do
    cond do
      password = Keyword.get(opts, :password) -> validate(password, :password)
      path = Keyword.get(opts, :password_file) -> read(path)
      true -> {:error, :no_password_configured}
    end
  end

  defp read(path) do
    case File.read(path) do
      # Trailing whitespace goes: a file written with `echo` ends in a newline,
      # and nobody intends that to be part of the password.
      {:ok, contents} -> contents |> String.trim_trailing() |> validate({:password_file, path})
      {:error, reason} -> {:error, {:password_unreadable, path, reason}}
    end
  end

  defp validate("", source), do: {:error, {:empty_password, source}}

  defp validate(password, source) when is_binary(password) do
    if String.length(password) < @short_password do
      Logger.warning(
        "iroh_console: the console password is shorter than #{@short_password} characters, " <>
          "which is weak against guessing (from #{inspect(source)})"
      )
    end

    {:ok, password}
  end

  defp validate(other, source), do: {:error, {:invalid_password, source, other}}
end
