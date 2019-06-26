defmodule Membrane.Testing.SourceTest do
  use ExUnit.Case
  alias Membrane.Testing.Source
  alias Membrane.Buffer

  test "Source when Initializing has cnt field in state equal to 0 if `:output` is a function" do
    output = fn _, _ -> nil end

    assert Source.handle_init(%Source{output: {nil, output}}) ==
             {:ok, %{output: output, generator_state: nil}}
  end

  describe "Source when handling demand" do
    test "sends next buffer if :output is an enumerable" do
      payloads = Enum.into(1..10, [])
      demand_size = 3

      assert {{:ok, actions}, state} =
               Source.handle_demand(:output, demand_size, :buffers, nil, %{output: payloads})

      assert [{:buffer, {:output, buffers}}] = actions

      buffers
      |> Enum.zip(1..demand_size)
      |> Enum.each(fn {%Buffer{payload: payload}, num} -> assert num == payload end)

      assert List.first(state.output) == demand_size + 1
      assert Enum.count(state.output) + demand_size == Enum.count(payloads)
    end

    test "sends end of stream if :output enumerable is empty (split returned [])" do
      payload = 1
      payloads = [payload]

      assert {{:ok, actions}, state} =
               Source.handle_demand(:output, 2, :buffers, nil, %{output: payloads})

      assert [
               {:buffer, {:output, [buffer]}},
               {:event, {:output, event}}
             ] = actions

      assert %Buffer{payload: payload} == buffer
      assert event = %Membrane.Event.EndOfStream{}
    end
  end
end