module TermBuf
  # What was held down alongside the key.
  #
  # The values are the xterm encoding minus one: a terminal sends `1` for no
  # modifier, `2` for shift, `3` for alt, and so on up.
  @[Flags]
  enum Modifiers : UInt8
    Shift
    Alt
    Ctrl

    # The windows, command, or meta key, depending on whose keyboard it is.
    Super
  end

  # One key press.
  #
  # A key is a value: it says which key, which modifiers, and for an ordinary
  # character which character. What the terminal sent to say so is on the
  # `Events::Key` that carries it, since two terminals can send different bytes
  # for the same key and an application should not have to care.
  #
  # Modifiers are only as good as the terminal's encoding. `Ctrl` with a letter
  # arrives as one control byte, so `Ctrl+I` and `Tab` are the same key press
  # and nothing downstream can separate them. Terminals implementing the kitty
  # keyboard protocol can, which is why that protocol exists.
  struct Key
    # Which key, with `Character` meaning "the one in `#char`".
    enum Name : UInt8
      Character

      Enter
      Tab
      Backspace
      Escape

      Up
      Down
      Right
      Left

      Home
      End
      PageUp
      PageDown
      Insert
      Delete

      # The centre of the keypad with num lock off, which sends its own
      # sequence rather than a digit.
      Begin

      F1
      F2
      F3
      F4
      F5
      F6
      F7
      F8
      F9
      F10
      F11
      F12
      F13
      F14
      F15
      F16
      F17
      F18
      F19
      F20

      # An escape sequence the decoder does not recognise. The bytes are on the
      # event, so an application that knows better than the decoder still can.
      Unknown
    end

    # Which key, with `Name::Character` meaning the one in `#char`.
    getter name : Name

    # The character pressed, for a `Character` key. `'\0'` for anything else.
    getter char : Char

    # What was held down with it.
    getter modifiers : Modifiers

    def initialize(@name : Name, @char : Char = '\0', @modifiers : Modifiers = Modifiers::None)
    end

    # An ordinary character key.
    def self.character(char : Char, modifiers : Modifiers = Modifiers::None) : Key
      new Name::Character, char, modifiers
    end

    # A named key.
    def self.named(name : Name, modifiers : Modifiers = Modifiers::None) : Key
      new name, '\0', modifiers
    end

    # Whether this is an ordinary character rather than a named key.
    def character? : Bool
      @name.character?
    end

    # Whether control was held.
    def ctrl? : Bool
      @modifiers.ctrl?
    end

    # Whether alt was held.
    def alt? : Bool
      @modifiers.alt?
    end

    # Whether shift was held.
    def shift? : Bool
      @modifiers.shift?
    end

    # Whether the windows, command, or meta key was held.
    def super? : Bool
      @modifiers.super?
    end

    # Whether this is *char* with no modifiers but shift, which is what asking
    # "did they type a q" means.
    def is?(char : Char) : Bool
      character? && @char == char && (@modifiers & ~Modifiers::Shift).none?
    end

    # Whether this is the named key, whatever was held down with it.
    def is?(name : Name) : Bool
      @name == name
    end

    # A form suited to a key binding table: `Ctrl+C`, `Alt+Up`, `Shift+F5`.
    def to_s(io : IO) : Nil
      io << "Ctrl+" if ctrl?
      io << "Alt+" if alt?
      io << "Shift+" if shift?
      io << "Super+" if super?

      character? ? io << label : io << @name
    end

    # The printable name of a character key, which for the ones that are hard
    # to see is a word rather than the character itself.
    private def label : String
      case @char
      when ' '  then "Space"
      when '\0' then "Nul"
      else
        ctrl? ? @char.upcase.to_s : @char.to_s
      end
    end
  end
end
