defmodule Membrane.Caps.Matcher do
  import Kernel, except: [match?: 2]

  alias Membrane.Helper

  @type caps_spec :: {module()} | {module(), keyword()}
  @type caps_specs :: :any | caps_spec() | [caps_spec()]

  @doc """
  Function used to make sure caps specs are valid.

  In particular, valid caps:

  * Have shape described by caps_specs() type
  * If they contain keyword list, the keys are present in requested caps type

  It returns :ok when caps are valid and {:error, reason} otherwise
  """
  @spec validate_specs(caps_specs() | any()) :: :ok | {:error, reason :: tuple()}
  def validate_specs(specs_list) when is_list(specs_list) do
    specs_list |> Helper.Enum.each_with(&validate_specs/1)
  end

  def validate_specs({type, keyword_specs}) do
    caps = type.__struct__
    caps_keys = caps |> Map.from_struct() |> Map.keys() |> MapSet.new()
    spec_keys = keyword_specs |> Keyword.keys() |> MapSet.new()

    if MapSet.subset?(spec_keys, caps_keys) do
      :ok
    else
      invalid_keys = MapSet.difference(spec_keys, caps_keys) |> MapSet.to_list()
      {:error, {:invalid_keys, type, invalid_keys}}
    end
  end

  def validate_specs({_type}), do: :ok
  def validate_specs(:any), do: :ok
  def validate_specs(specs), do: {:error, {:invalid_specs, specs}}

  @doc """
  Function determining whether the caps match provided specs.

  When :any is used as specs, caps can by anything (i.e. they can be invalid)
  """
  @spec match?(:any, any()) :: true
  @spec match?(caps_specs(), struct()) :: boolean()
  def match?(:any, _), do: true

  def match?(specs, %_{} = caps) when is_list(specs) do
    specs |> Enum.any?(fn spec -> match?(spec, caps) end)
  end

  def match?({type, keyword_specs}, %caps_type{} = caps) do
    type == caps_type && keyword_specs |> Enum.all?(fn kv -> kv |> match_caps_entry(caps) end)
  end

  def match?({type}, %caps_type{}) do
    type == caps_type
  end

  defp match_caps_entry({spec_key, spec_value}, %{} = caps) do
    with {:ok, caps_value} <- caps |> Map.fetch(spec_key) do
      match_value(spec_value, caps_value)
    else
      _ -> false
    end
  end

  defp match_value(spec, value) when is_list(spec) do
    value in spec
  end

  defp match_value({min, max}, value) do
    min <= value && value <= max
  end

  defp match_value(spec, value) do
    spec == value
  end
end
