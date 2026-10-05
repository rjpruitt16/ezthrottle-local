defmodule EzthrottleLocal.Jitter do
  @moduledoc false

  @default_ratio 0.10

  def add_ms(ms, ratio \\ @default_ratio)

  def add_ms(ms, _ratio) when not is_integer(ms) or ms <= 0, do: ms

  def add_ms(ms, ratio) do
    ceiling = max(trunc(ms * ratio), 1)
    ms + :rand.uniform(ceiling)
  end
end
