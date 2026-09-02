module TermBuf
  {% begin %}
    # The shard's version, read from `shard.yml` at compile time.
    #
    # The directory is passed explicitly because `shards version` searches
    # upward from wherever it is run, and when this shard is compiled as a
    # dependency that is the *consumer's* project. Without it a library reports
    # whatever version the application using it happens to carry.
    #
    # Single quoted with any embedded single quote closed and reopened, which
    # is what makes every other character — spaces, double quotes, dollars,
    # backslashes — literal to the shell. The command is built before the
    # backtick and inserted with `id`, because interpolating a `StringLiteral`
    # into a backtick inserts its inspected form, quotes and escapes and all.
    {% command = "shards version '" + __DIR__.gsub(%r{'}, "'\\''") + "'" %}

    VERSION = {{ `#{command.id}`.strip.stringify }}
  {% end %}
end
