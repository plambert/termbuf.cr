require "./core/color"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # The terminal's own colours: the default foreground and background, the
  # cursor, and the 256 entry palette everything indexed resolves through.
  #
  # These are not cell attributes. Changing one repaints nothing and shows up
  # everywhere at once, including in text this shard never wrote.
  #
  # Which is why it is all gated on `Capability::KittyColorStack`. The stack is
  # what makes a change reversible: push, change what you like, pop, and the
  # terminal is as it was. Without somewhere to put the old values there is no
  # way to give them back, and a shard that leaves a terminal a different colour
  # than it found it is worse than one that leaves the colours alone.
  #
  #     terminal.colors.push
  #     terminal.colors.background = Color.rgb(20, 20, 30)
  #     # ...
  #     terminal.colors.pop
  #
  # `Terminal#close` pops whatever is still pushed, so an application that
  # forgets, or that stops on a signal, still gives the terminal back.
  class ColorStack
    CSI = "\e["
    OSC = "\e]"
    ST  = "\e\\"

    # How deep the stack is, counting only what this object pushed.
    getter depth : Int32 = 0

    # What the terminal can do, which for everything here means one flag.
    getter capabilities : Capabilities

    def initialize(@capabilities : Capabilities, &@sink : Bytes -> Nil)
    end

    # Whether the terminal will take any of this.
    def available? : Bool
      @capabilities.includes? Capability::KittyColorStack
    end

    # Saves the terminal's current colours so `#pop` can put them back.
    def push : Nil
      return unless available?

      @depth += 1
      write "#{CSI}#P"
    end

    # Restores the colours saved by the matching `#push`. Does nothing when
    # nothing is pushed, so an extra pop cannot walk off the end of a stack
    # something else was using.
    def pop : Nil
      return unless available?
      return if @depth.zero?

      @depth -= 1
      write "#{CSI}#Q"
    end

    # Pops everything this object pushed.
    def pop_all : Nil
      while @depth > 0
        pop
      end
    end

    # Runs the block with the colours saved, and puts them back however it ends.
    def saved(& : ->) : Nil
      push

      begin
        yield
      ensure
        pop
      end
    end

    {% for name, code in {foreground: 10, background: 11, cursor: 12,
                          selection_foreground: 19, selection_background: 17} %}
      # Sets the terminal's {{ name.id.stringify.gsub(/_/, " ").id }} colour.
      def {{ name.id }}=(color : Color) : Color
        write "#{OSC}{{ code }};#{specification color}#{ST}"
        color
      end
    {% end %}

    # Sets one entry of the 256 colour palette.
    def []=(index : Int32, color : Color) : Color
      raise ArgumentError.new "palette index #{index} is outside 0..255" unless 0 <= index <= 255

      write "#{OSC}4;#{index};#{specification color}#{ST}"
      color
    end

    # Puts the palette and the default colours back to what the terminal was
    # configured with, which is not the same as what was pushed.
    def reset : Nil
      write "#{OSC}104#{ST}#{OSC}110#{ST}#{OSC}111#{ST}#{OSC}112#{ST}"
    end

    # The X11 form, which every terminal understanding these sequences reads.
    # An indexed colour resolves through the standard palette first, since
    # naming a palette entry as the value of another one is a loop.
    private def specification(color : Color) : String
      red, green, blue = color.channels

      "rgb:%02x/%02x/%02x" % {red, green, blue}
    end

    private def write(text : String) : Nil
      return unless available?

      @sink.call text.to_slice
    end
  end
end
