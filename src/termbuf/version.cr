module TermBuf
  {% begin %}
  VERSION = {{ `shards version`.strip.stringify }}
  {% end %}
end
