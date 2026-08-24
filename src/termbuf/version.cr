module TermBuf
  {% begin %}
  # The shard's version, read from `shard.yml` at compile time.
  VERSION = {{ `shards version`.strip.stringify }}
  {% end %}
end
