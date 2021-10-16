defmodule Matrix2051.MatrixClient.Poller do
  @moduledoc """
    Queries the homeserver for new events; including the initial sync.
  """
  use Task, restart: :permanent

  def start_link(args) do
    Task.start_link(__MODULE__, :poll, [args])
  end

  def poll(args) do
    {sup_pid} = args
    Registry.register(Matrix2051.Registry, {sup_pid, :matrix_poller}, nil)

    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)

    if Matrix2051.IrcConn.State.registered(irc_state) do
      loop_poll(sup_pid, nil)
    else
      receive do
        :start_polling -> loop_poll(sup_pid, nil)
      end
    end
  end

  def loop_poll(sup_pid, since) do
    client = Matrix2051.IrcConn.Supervisor.matrix_client(sup_pid)

    case Matrix2051.MatrixClient.Client.raw_client(client) do
      nil ->
        # Wait for it to be initialized
        receive do
          :connected -> loop_poll(sup_pid, nil)
        end

      raw_client ->
        since = poll_one(sup_pid, since, raw_client)
        loop_poll(sup_pid, since)
    end
  end

  defp poll_one(sup_pid, since, raw_client) do
    query = %{
      # Completely arbitrary value. Just make sure it's lower than recv_timeout below
      "timeout" => "600"
    }

    query =
      case since do
        nil -> query
        _ -> Map.put(query, "since", since)
      end

    path = "/_matrix/client/r0/sync?" <> URI.encode_query(query)

    # Need to be larger than the timeout above (time 1000 because this ones seems
    # to be in milliseconds)
    options = [recv_timeout: 1_000_000]

    case Matrix2051.Matrix.RawClient.get(raw_client, path, [], options) do
      {:ok, events} ->
        handle_events(sup_pid, events)
        events["next_batch"]
    end
  end

  @doc """
    Internal method that dispatches event; public only so it can be unit-tested.
  """
  def handle_events(sup_pid, events) do
    events
    |> Map.get("rooms", %{})
    |> Map.get("join", %{})
    |> Map.to_list()
    |> Enum.map(fn {room_id, event} -> handle_joined_room(sup_pid, room_id, event) end)

    events
    |> Map.get("rooms", %{})
    |> Map.get("leave", %{})
    |> Map.to_list()
    |> Enum.map(fn {room_id, event} -> handle_left_room(sup_pid, room_id, event) end)

    events
    |> Map.get("rooms", %{})
    |> Map.get("invite", %{})
    |> Map.to_list()
    |> Enum.map(fn {room_id, event} -> handle_invited_room(sup_pid, room_id, event) end)
  end

  defp handle_joined_room(sup_pid, room_id, room_event) do
    new_rooms =
      room_event
      |> Map.get("state", %{})
      |> Map.get("events", [])
      # oldest first
      |> Enum.map(fn event ->
        sender =
          case Map.get(event, "sender") do
            nil -> nil
            sender -> String.replace_prefix(sender, "@", "")
          end

        handle_event(sup_pid, room_id, sender, true, event)
      end)

    # Send self JOIN, RPL_TOPIC/RPL_NOTOPIC, RPL_NAMREPLY
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)

    new_rooms
    |> Enum.filter(fn room -> room != nil end)
    # dedup
    |> Map.new()
    |> Map.to_list()
    |> Enum.map(fn {room_id, {canonical_alias_sender, old_canonical_alias}} ->
      send_channel_welcome(
        sup_pid,
        room_id,
        canonical_alias_sender,
        old_canonical_alias,
        nil
      )

      Matrix2051.MatrixClient.State.mark_synced(state, room_id)
    end)

    room_event
    |> Map.get("timeline", %{})
    |> Map.get("events", [])
    # oldest first
    |> Enum.map(fn event ->
      sender =
        case Map.get(event, "sender") do
          nil -> nil
          sender -> String.replace_prefix(sender, "@", "")
        end

      handle_event(sup_pid, room_id, sender, false, event)
    end)
  end

  defp handle_event(
         sup_pid,
         room_id,
         sender,
         state_event,
         %{"type" => "m.room.canonical_alias"} = event
       ) do
    new_canonical_alias = event["content"]["alias"]
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)

    old_canonical_alias =
      Matrix2051.MatrixClient.State.set_room_canonical_alias(
        state,
        room_id,
        new_canonical_alias
      )

    if !state_event do
      send_channel_welcome(sup_pid, room_id, sender, old_canonical_alias, event)
    end

    {room_id, {sender, old_canonical_alias}}
  end

  defp handle_event(
         sup_pid,
         room_id,
         sender,
         state_event,
         %{"type" => "m.room.join_rules"} = event
       ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, event)

    if !state_event do
      mode =
        case event["content"]["join_rule"] do
          "public" -> "-i"
          "knock" -> "+i"
          "invite" -> "+i"
          "private" -> "+i"
        end

      send.(%Matrix2051.Irc.Command{
        tags: %{"account" => sender},
        source: nick2nuh(sender),
        command: "MODE",
        params: [channel, mode]
      })
    end

    nil
  end

  defp handle_event(
         sup_pid,
         room_id,
         sender,
         state_event,
         %{"type" => "m.room.member"} = event
       ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    send = make_send_function(sup_pid, event)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

    was_already_member = Matrix2051.MatrixClient.State.room_member_add(state, room_id, sender)

    if !state_event && !was_already_member do
      send.(%Matrix2051.Irc.Command{
        tags: %{"account" => sender},
        source: nick2nuh(sender),
        command: "JOIN",
        params: [channel, sender, sender]
      })
    end

    nil
  end

  defp handle_event(
         sup_pid,
         room_id,
         sender,
         _state_event,
         %{"type" => "m.room.message"} = event
       ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    send = make_send_function(sup_pid, event)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

    tags = %{"account" => sender}

    {reply_to, tags} =
      case event["content"] do
        %{"m.relates_to" => %{"m.in_reply_to" => %{"event_id" => reply_to}}} ->
          {reply_to, Map.put(tags, "+draft/reply", reply_to)}

        _ ->
          {nil, tags}
      end

    {command, body} =
      case event["content"] do
        %{"msgtype" => "m.text", "body" => body} ->
          # TODO: if "format" key is present, parse the HTML and convert it to IRC formatting
          body =
            if reply_to do
              # Strip the fallback, as described in
              # https://matrix.org/docs/spec/client_server/r0.6.1#stripping-the-fallback
              body
              |> String.split("\n")
              |> Enum.drop_while(fn line -> String.starts_with?(line, "> ") end)
              |> Enum.join("\n")
              |> String.trim_leading("\n")
            else
              body
            end

          {"PRIVMSG", body}

        %{"msgtype" => "m.emote", "body" => body} ->
          # TODO: ditto
          {"PRIVMSG", "\x01ACTION " <> body <> "\x01"}

        %{"msgtype" => "m.notice", "body" => body} ->
          # TODO: ditto
          {"NOTICE", body}

        %{"msgtype" => "m.image", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"msgtype" => "m.file", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"msgtype" => "m.audio", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"msgtype" => "m.location", "body" => body, "geo_uri" => geo_uri} ->
          {"PRIVMSG", body <> " (" <> geo_uri <> ")"}

        %{"msgtype" => "m.video", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"body" => body} ->
          # fallback
          {"PRIVMSG", body}
      end

    case String.split(body, "\n") do
      [] ->
        nil

      [line] ->
        send.(%Matrix2051.Irc.Command{
          tags: tags,
          source: nick2nuh(sender),
          command: command,
          params: [channel, line]
        })

      lines ->
        writer = Matrix2051.IrcConn.Supervisor.writer(sup_pid)
        irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
        capabilities = Matrix2051.IrcConn.State.capabilities(irc_state)
        batch_reference_tag = Base.encode32(event["event_id"], padding: false)

        # open batch
        send.(%Matrix2051.Irc.Command{
          tags: tags,
          source: nick2nuh(sender),
          command: "BATCH",
          params: ["+" <> batch_reference_tag, "draft/multiline", channel]
        })

        # send content
        Enum.map(lines, fn line ->
          cmd = %Matrix2051.Irc.Command{
            tags: %{"batch" => batch_reference_tag},
            source: nick2nuh(sender),
            command: command,
            params: [channel, line]
          }

          Matrix2051.IrcConn.Writer.write_command(
            writer,
            Matrix2051.Irc.Command.downgrade(cmd, capabilities)
          )
        end)

        # close batch
        cmd = %Matrix2051.Irc.Command{
          command: "BATCH",
          params: ["-" <> batch_reference_tag]
        }

        Matrix2051.IrcConn.Writer.write_command(
          writer,
          Matrix2051.Irc.Command.downgrade(cmd, capabilities)
        )
    end

    nil
  end

  defp handle_event(
         sup_pid,
         room_id,
         sender,
         state_event,
         %{"type" => "m.room.name"} = event
       ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    send = make_send_function(sup_pid, event)

    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    Matrix2051.MatrixClient.State.set_room_name(state, room_id, event["content"]["name"])

    if !state_event do
      topic =
        case compute_topic(sup_pid, room_id) do
          nil -> ""
          {topic, _whotime} -> topic
        end

      send.(%Matrix2051.Irc.Command{
        source: nick2nuh(sender),
        command: "TOPIC",
        params: [channel, topic]
      })
    end

    nil
  end

  defp handle_event(
         sup_pid,
         room_id,
         sender,
         state_event,
         %{"type" => "m.room.topic"} = event
       ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    send = make_send_function(sup_pid, event)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

    Matrix2051.MatrixClient.State.set_room_topic(
      state,
      room_id,
      {event["content"]["topic"], sender, event["origin_server_ts"]}
    )

    if !state_event do
      topic =
        case compute_topic(sup_pid, room_id) do
          nil -> ""
          {topic, _whotime} -> topic
        end

      send.(%Matrix2051.Irc.Command{
        source: nick2nuh(sender),
        command: "TOPIC",
        params: [channel, topic]
      })
    end

    nil
  end

  defp handle_event(sup_pid, room_id, _sender, _state_event, event) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    send = make_send_function(sup_pid, event)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

    case event["type"] do
      "m.room.create" ->
        nil

      "m.room.history_visibility" ->
        nil

      event_type ->
        send.(%Matrix2051.Irc.Command{
          source: "server",
          command: "NOTICE",
          params: [
            channel,
            "Unknown state event (" <> event_type <> "): " <> Kernel.inspect(event)
          ]
        })
    end

    nil
  end

  defp handle_left_room(sup_pid, _room_id, _event) do
    _state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    _writer = Matrix2051.IrcConn.Supervisor.writer(sup_pid)
    # TODO
  end

  defp handle_invited_room(sup_pid, room_id, room_event) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    nick = Matrix2051.IrcConn.State.nick(irc_state)

    room_event
    |> Map.get("invite_state", %{})
    |> Map.get("events", [])
    # oldest first
    |> Enum.map(fn event ->
      send = make_send_function(sup_pid, event)

      sender =
        case Map.get(event, "sender") do
          nil -> nil
          sender -> String.replace_prefix(sender, "@", "")
        end

      case event do
        %{"type" => "m.room.member"} ->
          send.(%Matrix2051.Irc.Command{
            tags: %{"account" => sender},
            source: nick2nuh(sender),
            command: "INVITE",
            params: [nick, room_id]
          })

        _ ->
          nil
      end
    end)
  end

  defp compute_topic(sup_pid, room_id) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    name = Matrix2051.MatrixClient.State.room_name(state, room_id)
    topicwhotime = Matrix2051.MatrixClient.State.room_topic(state, room_id)

    case {name, topicwhotime} do
      {nil, nil} -> nil
      {name, nil} -> {"[" <> name <> "]", nil}
      {nil, {topic, who, time}} -> {"[] " <> topic, {who, time}}
      {name, {topic, who, time}} -> {"[" <> name <> "] " <> topic, {who, time}}
    end
  end

  # Sends self JOIN, RPL_TOPIC/RPL_NOTOPIC, RPL_NAMREPLY
  defp send_channel_welcome(
         sup_pid,
         room_id,
         canonical_alias_sender,
         old_canonical_alias,
         event
       ) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    nick = Matrix2051.IrcConn.State.nick(irc_state)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

    send = make_send_function(sup_pid, event)

    # Join the new channel
    send.(%Matrix2051.Irc.Command{
      tags: %{"account" => nick},
      source: nick2nuh(nick),
      command: "JOIN",
      params: [channel, nick, nick]
    })

    case compute_topic(sup_pid, room_id) do
      nil ->
        # RPL_NOTOPIC
        send.(%Matrix2051.Irc.Command{command: "331", params: [nick, channel]})

      {topic, whotime} ->
        # RPL_TOPIC
        send.(%Matrix2051.Irc.Command{
          command: "332",
          params: [nick, channel, topic]
        })

        case whotime do
          nil ->
            nil

          {who, time} ->
            # RPL_TOPICWHOTIME
            send.(%Matrix2051.Irc.Command{
              command: "333",
              params: [nick, channel, who, Integer.to_string(div(time, 1000))]
            })
        end
    end

    # send RPL_NAMREPLY
    Matrix2051.MatrixClient.State.room_members(state, room_id)
    |> Enum.map(fn member ->
      # TODO: group them in lines

      # RPL_NAMREPLY
      send.(%Matrix2051.Irc.Command{
        command: "353",
        params: [nick, "=", channel, member]
      })
    end)

    # RPL_ENDOFNAMES
    send.(%Matrix2051.Irc.Command{
      command: "366",
      params: [nick, channel, "End of /NAMES list"]
    })

    if old_canonical_alias != nil do
      announce_channel_rename(
        Matrix2051.IrcConn.Supervisor,
        sup_pid,
        room_id,
        canonical_alias_sender,
        old_canonical_alias
      )
    end
  end

  defp announce_channel_rename(
         Matrix2051.IrcConn.Supervisor,
         sup_pid,
         room_id,
         canonical_alias_sender,
         old_canonical_alias
       ) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    nick = Matrix2051.IrcConn.State.nick(irc_state)
    new_canonical_alias = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

    send = make_send_function(sup_pid, nil)

    # this is a known room that got renamed; part the old channel.
    send.(%Matrix2051.Irc.Command{
      tags: %{"account" => nick},
      source: nick2nuh(nick),
      command: "PART",
      params: [
        old_canonical_alias,
        canonical_alias_sender <> " renamed this room to " <> new_canonical_alias
      ]
    })

    # Announce the rename in the new room
    send.(%Matrix2051.Irc.Command{
      source: "server",
      command: "NOTICE",
      params: [
        new_canonical_alias,
        canonical_alias_sender <> " renamed this room from " <> old_canonical_alias
      ]
    })
  end

  defp format_url(url) do
    case URI.parse(url) do
      %{scheme: "mxc", host: host, path: path} ->
        "https://#{host}/_matrix/media/r0/download/#{host}#{path}"

      _ ->
        url
    end
  end

  # Returns a function that can be used to send messages
  defp make_send_function(sup_pid, event) do
    writer = Matrix2051.IrcConn.Supervisor.writer(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    capabilities = Matrix2051.IrcConn.State.capabilities(state)

    fn cmd ->
      cmd =
        case event do
          nil ->
            cmd

          _ ->
            new_tags = %{}

            new_tags =
              case Map.get(event, "origin_server_ts") do
                nil ->
                  new_tags

                origin_server_ts ->
                  time =
                    origin_server_ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

                  Map.put(new_tags, "time", time)
              end

            new_tags =
              case Map.get(event, "event_id") do
                nil -> new_tags
                event_id -> Map.put(new_tags, "msgid", event_id)
              end

            {is_echo, new_tags} =
              case Map.get(event, "unsigned") do
                %{"transaction_id" => transaction_id} ->
                  label = Matrix2051.MatrixClient.Client.transaction_id_to_label(transaction_id)

                  if label == nil do
                    {true, new_tags}
                  else
                    {true, Map.put(new_tags, "label", label)}
                  end

                _ ->
                  {false, new_tags}
              end

            %{cmd | tags: Map.merge(cmd.tags, new_tags), is_echo: is_echo}
        end

      Matrix2051.IrcConn.Writer.write_command(
        writer,
        Matrix2051.Irc.Command.downgrade(cmd, capabilities)
      )
    end
  end

  defp nick2nuh(nick) do
    [local_name, hostname] = String.split(nick, ":", parts: 2)
    "#{nick}!#{local_name}@#{hostname}"
  end
end
