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
    #
    # Windows has no shell in the way: the command line goes to the program
    # as it is, and only double quotes group a path with spaces in it. A
    # Windows path cannot hold a double quote, so none needs escaping there.
    {% if flag?(:win32) %}
      {% command = "shards version \"" + __DIR__ + "\"" %}
    {% else %}
      {% command = "shards version '" + __DIR__.gsub(%r{'}, "'\\''") + "'" %}
    {% end %}

    VERSION = {{ `#{command.id}`.strip.stringify }}
  {% end %}
end
