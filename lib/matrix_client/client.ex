defmodule Matrix2051.MatrixClient.Client do
  @moduledoc """
    Manages connections to a Matrix homeserver.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(args) do
    {:ok, {:initial_state, args}}
  end

  @impl true
  def handle_call({:dump_state}, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:connect, local_name, hostname, password}, _from, state) do
    case state do
      {:initial_state, {irc_mod, irc_pid, args}} ->
        httpoison = Keyword.get(args, :httpoison, HTTPoison)
        base_url = get_base_url(hostname, httpoison)

        # Check the server supports password login
        %HTTPoison.Response{status_code: 200, body: body} =
          httpoison.get!(base_url <> "/_matrix/client/r0/login")

        data = Jason.decode!(body)

        flow =
          case data["flows"] do
            flows when is_list(flows) ->
              Enum.find(flows, nil, fn flow -> flow["type"] == "m.login.password" end)

            _ ->
              nil
          end

        case flow do
          nil ->
            {:reply, {:error, :no_password_flow, "No password flow"}, state}

          _ ->
            body =
              Jason.encode!(%{
                "type" => "m.login.password",
                "user" => local_name,
                "password" => password
              })

            case httpoison.post!(base_url <> "/_matrix/client/r0/login", body) do
              %HTTPoison.Response{status_code: 200, body: body} ->
                data = Jason.decode!(body)

                if data["user_id"] != "@" <> local_name <> ":" <> hostname do
                  raise "Unexpected user_id: " <> data["user_id"]
                end

                access_token = data["access_token"]

                raw_client = %Matrix2051.Matrix.RawClient{
                  base_url: base_url,
                  access_token: access_token,
                  httpoison: httpoison
                }

                state =
                  {:connected,
                   [
                     irc_mod: irc_mod,
                     irc_pid: irc_pid,
                     raw_client: raw_client,
                     local_name: local_name,
                     hostname: hostname
                   ]}

                {:reply, {:ok}, state}

              %HTTPoison.Response{status_code: 403, body: body} ->
                data = Jason.decode!(body)
                {:reply, {:error, :denied, data["error"]}, state}
            end
        end

      {:connected, {_raw_client, local_name, hostname}} ->
        {:reply, {:error, {:already_connected, local_name, hostname}}, state}
    end
  end

  @impl true
  def handle_call({:register, local_name, hostname, password}, _from, state) do
    case state do
      {:initial_state, {irc_mod, irc_pid, args}} ->
        httpoison = Keyword.get(args, :httpoison, HTTPoison)
        base_url = get_base_url(hostname, httpoison)

        # XXX: This is not part of the Matrix specification;
        # but there is nothing else we can do to support registration.
        # This seems to be only documented here:
        # https://matrix.org/docs/guides/client-server-api/#accounts
        body =
          Jason.encode!(%{
            "auth" => %{type: "m.login.dummy"},
            "username" => local_name,
            "password" => password
          })

        case httpoison.post!(base_url <> "/_matrix/client/r0/register", body) do
          %HTTPoison.Response{status_code: 200, body: body} ->
            data = Jason.decode!(body)

            # TODO: check data["user_id"]
            {_, user_id} = String.split_at(data["user_id"], 1)
            access_token = data["access_token"]

            raw_client = %Matrix2051.Matrix.RawClient{
              base_url: base_url,
              access_token: access_token,
              httpoison: httpoison
            }

            state =
              {:connected,
               [
                 irc_mod: irc_mod,
                 irc_pid: irc_pid,
                 raw_client: raw_client,
                 local_name: local_name,
                 hostname: hostname
               ]}

            {:reply, {:ok, user_id}, state}

          %HTTPoison.Response{status_code: 400, body: body} ->
            data = Jason.decode!(body)

            case data do
              %{errcode: "M_USER_IN_USE", error: message} ->
                {:reply, {:error, :user_in_use, message}, state}

              %{errcode: "M_INVALID_USERNAME", error: message} ->
                {:reply, {:error, :invalid_username, message}, state}

              %{errcode: "M_EXCLUSIVE", error: message} ->
                {:reply, {:error, :exclusive, message}, state}
            end

          %HTTPoison.Response{status_code: 403, body: body} ->
            data = Jason.decode!(body)
            {:reply, {:error, :unknown, data["error"]}, state}

          %HTTPoison.Response{status_code: _, body: body} ->
            {:reply, {:error, :unknown, Kernel.inspect(body)}, state}
        end

      {:connected, {_raw_client, local_name, hostname}} ->
        {:reply, {:error, {:already_connected, local_name, hostname}}, state}
    end
  end

  defp get_base_url(hostname, httpoison) do
    case httpoison.get!("https://" <> hostname <> "/.well-known/matrix/client") do
      %HTTPoison.Response{status_code: 200, body: body} ->
        data = Jason.decode!(body)
        data["m.homeserver"]["base_url"]

      %HTTPoison.Response{status_code: 404} ->
        "https://" <> hostname

      _ ->
        # The next call will probably fail, but this spares error handling in this one.
        "https://" <> hostname
    end
  end

  def connect(pid, local_name, hostname, password) do
    GenServer.call(pid, {:connect, local_name, hostname, password})
  end

  def user_id(pid) do
    case GenServer.call(pid, {:dump_state}) do
      {:connect, state} -> state[:local_name] <> ":" <> state[:hostname]
      {:initial_state, _} -> nil
    end
  end

  def register(pid, local_name, hostname, password) do
    GenServer.call(pid, {:register, local_name, hostname, password})
  end
end
