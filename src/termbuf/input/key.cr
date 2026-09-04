module TermBuf::Input
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

      # Everything below arrives only from a terminal speaking the kitty
      # keyboard protocol, which reports these as code points in the private
      # use area. They are added at the end rather than in among their
      # relatives so that no existing member changes its value.

      # The lock and system keys, `CSI 57358 u` through `CSI 57363 u`.
      CapsLock
      ScrollLock
      NumLock
      PrintScreen
      Pause
      Menu

      # The function keys past the twenty a `~` sequence can name.
      F21
      F22
      F23
      F24
      F25
      F26
      F27
      F28
      F29
      F30
      F31
      F32
      F33
      F34
      F35

      # The keypad, which the kitty protocol reports apart from the keys it
      # shares a meaning with: `KP1` is not `End` and `KPEnter` is not `Enter`,
      # however identical they look to an ordinary terminal.
      KP0
      KP1
      KP2
      KP3
      KP4
      KP5
      KP6
      KP7
      KP8
      KP9
      KPDecimal
      KPDivide
      KPMultiply
      KPSubtract
      KPAdd
      KPEnter
      KPEqual
      KPSeparator
      KPLeft
      KPRight
      KPUp
      KPDown
      KPPageUp
      KPPageDown
      KPHome
      KPEnd
      KPInsert
      KPDelete
      KPBegin

      # The media keys, which a keyboard with them sends whether or not the
      # application asked for anything.
      MediaPlay
      MediaPause
      MediaPlayPause
      MediaReverse
      MediaStop
      MediaFastForward
      MediaRewind
      MediaTrackNext
      MediaTrackPrevious
      MediaRecord
      LowerVolume
      RaiseVolume
      MuteVolume

      # The modifier keys themselves, reported as keys of their own. Only a
      # terminal asked for key events for them sends these; the modifier bits
      # on another key are `Modifiers`, not these.
      LeftShift
      LeftControl
      LeftAlt
      LeftSuper
      LeftHyper
      LeftMeta
      RightShift
      RightControl
      RightAlt
      RightSuper
      RightHyper
      RightMeta
      IsoLevel3Shift
      IsoLevel5Shift
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

    # Reads back what `#to_s` writes: a space separated sequence of key
    # descriptions.
    #
    # Each description is zero or more of the prefixes `Ctrl+`, `Alt+`,
    # `Shift+` and `Super+`, in any order and any case, followed by a `Name`
    # label, the `Space` or `Nul` label, or a single character. A space is an
    # unambiguous separator because the space key is written `Space`, so
    # `"Ctrl+X s"` is two keys and `"Ctrl+Space"` is one.
    #
    # Descriptions are normalised to what `Decoder` emits for the same key
    # press, so a binding table built from text matches the keys an application
    # is handed. See `.parse_one`.
    #
    # A string of nothing but whitespace is an empty sequence; an empty
    # description is an `ArgumentError`, as is an unknown name, a trailing
    # modifier, and anything longer than one character that is not a name.
    def self.parse(text : String) : Array(Key)
      text.split.map { |description| parse_one description }
    end

    # One key description, as `.parse` reads them.
    #
    # `Ctrl` with a character is a single C0 control byte on the wire, and
    # several of those bytes are a named key: no terminal can tell `Ctrl+I`
    # from `Tab`, so both have to become the key the decoder emits for `0x09`.
    # That gives `Ctrl+I` => `Tab`, `Ctrl+M` and `Ctrl+J` => `Enter`, and
    # `Ctrl+[` => `Escape`, each keeping whatever else was held down.
    #
    # `Ctrl+H` is the one that keeps its modifier. `0x08` reaches the decoder
    # as `Ctrl+Backspace` and `0x7F` as a bare `Backspace`, because a keyboard
    # with both keys sends the two bytes and an application is entitled to bind
    # them apart; stripping the `Ctrl` would fold the two together.
    #
    # The same rule settles case, since `Ctrl+A` and `Ctrl+a` are one byte and
    # the decoder calls it lower case.
    def self.parse_one(text : String) : Key
      raise ArgumentError.new "a key description cannot be empty" if text.empty?

      held = Modifiers::None
      rest = text

      # A leading `+` is the plus key rather than an empty modifier, which is
      # what leaves the last one in `Ctrl++` to the key.
      while (plus = rest.index('+')) && plus > 0
        modifier = modifier_named rest[0, plus]
        break unless modifier

        held |= modifier
        rest = rest[(plus + 1)..]
      end

      normalise resolve(rest, held, text)
    end

    private def self.modifier_named(text : String) : Modifiers?
      case text.downcase
      when "ctrl"  then Modifiers::Ctrl
      when "alt"   then Modifiers::Alt
      when "shift" then Modifiers::Shift
      when "super" then Modifiers::Super
      end
    end

    # What is left of a description once its modifiers have been taken off.
    private def self.resolve(rest : String, held : Modifiers, text : String) : Key
      raise ArgumentError.new "#{text.inspect} ends with a modifier and no key" if rest.empty?

      case rest.downcase
      when "space" then return character ' ', held
      when "nul"   then return character '\0', held
      end

      # `Character` is the absence of a name rather than one an application can
      # ask for: the character itself, or `Nul`, is how that key is written.
      if (name = Name.parse? rest) && !name.character?
        return named name, held
      end

      return character rest[0], held if rest.size == 1

      if rest.includes? '+'
        raise ArgumentError.new "#{text.inspect} holds a modifier that is not Ctrl, Alt, Shift or Super"
      end

      raise ArgumentError.new "#{rest.inspect} in #{text.inspect} is neither a key name nor a single character"
    end

    # Folds a `Ctrl` and a character onto the key its control byte arrives as.
    private def self.normalise(key : Key) : Key
      return key unless key.character? && key.ctrl?
      return key unless byte = control_byte key.char

      base = from_control byte
      new base.name, base.char, base.modifiers | (key.modifiers & ~Modifiers::Ctrl)
    end

    # The C0 byte `Ctrl` and *char* stand for, or nil when the pair has no
    # control byte and so reaches the application as the two of them.
    private def self.control_byte(char : Char) : UInt8?
      case char
      when ' '      then 0x00_u8
      when '?'      then 0x7F_u8
      when 'a'..'z' then (char.ord - 0x60).to_u8
      when '@'..'_' then (char.ord - 0x40).to_u8
      end
    end

    # The key a C0 control byte is.
    #
    # There is one table and this is it: `Decoder` reads a control byte by
    # asking here, so what a binding table is written against and what an
    # application is handed cannot drift apart.
    #
    # Several of these bytes are two keys wearing one byte. `Ctrl+I` and `Tab`
    # are both `0x09`, `Ctrl+M` and `Enter` are both `0x0D`, and no amount of
    # care here separates them: it takes a terminal speaking the kitty keyboard
    # protocol, which reports the key and the modifier apart.
    def self.from_control(byte : UInt8) : Key
      case byte
      when 0x00       then character ' ', Modifiers::Ctrl
      when 0x08       then named Name::Backspace, Modifiers::Ctrl
      when 0x09       then named Name::Tab
      when 0x0A, 0x0D then named Name::Enter
      when 0x1B       then named Name::Escape
      when 0x7F       then named Name::Backspace
      when 0x01..0x1A then character (byte + 0x60).chr, Modifiers::Ctrl
      when 0x1C..0x1F then character (byte + 0x40).chr, Modifiers::Ctrl
      else                 character byte.chr
      end
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
        # Upper case is the convention for a control character, and only for
        # one: it is `Ctrl+C`, never `Ctrl+c`, but upper casing anything
        # outside ASCII changes the key rather than how it is spelled.
        ctrl? && @char.ascii_letter? ? @char.upcase.to_s : @char.to_s
      end
    end
  end
end
