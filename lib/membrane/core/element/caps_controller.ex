defmodule Membrane.Core.Element.CapsController do
  alias Membrane.{Caps, Core, Element}
  alias Core.{CallbackHandler, PullBuffer}
  alias Core.Element.{ActionHandler, PadModel}
  alias Element.Context
  require PadModel
  use Core.Element.Log

  def handle_caps(pad_name, caps, state) do
    PadModel.assert_data!(pad_name, %{direction: :sink}, state)
    data = PadModel.get_data!(pad_name, state)

    if data.mode == :pull and not (data.buffer |> PullBuffer.empty?()) do
      PadModel.update_data(
        pad_name,
        :buffer,
        &(&1 |> PullBuffer.store(:caps, caps)),
        state
      )
    else
      exec_handle_caps(pad_name, caps, state)
    end
  end

  def exec_handle_caps(pad_name, caps, state) do
    %{accepted_caps: accepted_caps, caps: old_caps} = PadModel.get_data!(pad_name, state)

    context = %Context.Caps{caps: old_caps}

    with :ok <- if(Caps.Matcher.match?(accepted_caps, caps), do: :ok, else: :invalid_caps),
         {:ok, state} <-
           CallbackHandler.exec_and_handle_callback(
             :handle_caps,
             ActionHandler,
             [pad_name, caps, context],
             state
           ) do
      PadModel.set_data(pad_name, :caps, caps, state)
    else
      :invalid_caps ->
        warn_error(
          """
          Received caps: #{inspect(caps)} that are not specified in known_sink_pads
          for pad #{inspect(pad_name)}. Specs of accepted caps are:
          #{inspect(accepted_caps, pretty: true)}
          """,
          :invalid_caps,
          state
        )

      {:error, reason} ->
        warn_error("Error while handling caps", reason, state)
    end
  end
end