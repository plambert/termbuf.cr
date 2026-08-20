module TermBuf
  # What the terminal on the other end can be asked to do.
  #
  # Detection fills this in; the encoder only reads it. Anything not known to
  # be supported is treated as unsupported, so a terminal nobody recognises
  # gets plain text rather than a screen full of escape sequences.
  @[Flags]
  enum Capability : UInt64
    # The eight colours of SGR 30-37 and 40-47.
    Color16

    # The 256 colour palette, through SGR 38;5 and 48;5.
    Color256

    # 24 bit colour, through SGR 38;2 and 48;2.
    TrueColor

    # The aixterm bright colour codes, SGR 90-97 and 100-107. Without this,
    # palette indices 8 through 15 fall back to their dim counterparts, and a
    # bright foreground picks up bold if bold is available.
    BrightColors

    Bold
    Faint
    Italic

    # SGR 4 and 24.
    Underline

    # The `4:2` through `4:5` subparameter underline styles. Without this,
    # every underline style degrades to a plain one.
    ExtendedUnderline

    # SGR 58 and 59, colouring the underline separately from the text.
    UnderlineColor

    Blink
    RapidBlink
    Reverse
    Conceal
    Strike
    Overline
    Superscript

    # DECSTBM and the SU/SD scroll commands, which is what lets a scrolled
    # region be moved rather than redrawn.
    ScrollRegion

    # IL and DL.
    InsertDeleteLine

    # ECH, erasing a run of cells without writing spaces over them.
    EraseChars

    # DEC private mode 2026, wrapping a paint so the terminal never shows a
    # half-drawn frame.
    SynchronizedOutput

    # The alternate screen buffer, DEC private mode 1049.
    AltScreen

    BracketedPaste
    FocusEvents
    MouseSgr
    KittyKeyboard
    Osc8Links
    KittyGraphics
    KittyGraphicsTempFile
    KittyColorStack
    Titles
    CursorShape
  end

  # A capability mask that keeps itself consistent.
  #
  # Support is capped, not limited: a terminal that can do 24 bit colour can
  # also do the 256 colour palette and the original sixteen, so setting the
  # broader capability implies the narrower ones. The encoder relies on that,
  # and checks only the capability it is about to use.
  struct Capabilities
    getter flags : Capability

    def initialize(flags : Capability = Capability::None)
      @flags = Capabilities.normalize flags
    end

    # Applies the implications a capability carries with it.
    def self.normalize(flags : Capability) : Capability
      flags |= Capability::Color256 if flags.true_color?
      flags |= Capability::Color16 if flags.color256?
      flags |= Capability::Underline if flags.extended_underline? || flags.underline_color?
      flags |= Capability::Blink if flags.rapid_blink?
      flags |= Capability::KittyGraphics if flags.kitty_graphics_temp_file?
      flags
    end

    def includes?(capability : Capability) : Bool
      @flags.includes? capability
    end

    def with(capability : Capability) : Capabilities
      Capabilities.new @flags | capability
    end

    # Removes a capability along with everything that implies it, so that
    # clearing `Color256` also clears `TrueColor` rather than leaving a mask
    # that claims both.
    def without(capability : Capability) : Capabilities
      remaining = @flags & ~capability

      remaining &= ~Capability::TrueColor unless remaining.color256?
      remaining &= ~(Capability::Color256 | Capability::TrueColor) unless remaining.color16?

      unless remaining.underline?
        remaining &= ~(Capability::ExtendedUnderline | Capability::UnderlineColor)
      end

      remaining &= ~Capability::RapidBlink unless remaining.blink?
      remaining &= ~Capability::KittyGraphicsTempFile unless remaining.kitty_graphics?

      Capabilities.new remaining
    end

    def to_s(io : IO) : Nil
      io << "Capabilities(" << @flags << ')'
    end

    # Nothing at all: plain text, no escape sequences. The starting point for
    # detection, and what an unrecognised terminal gets.
    NONE = new

    # What essentially every terminal emulator written since the 1980s does.
    ANSI = new Capability::Color16 | Capability::Bold | Capability::Underline |
               Capability::Reverse | Capability::Blink | Capability::ScrollRegion |
               Capability::InsertDeleteLine | Capability::AltScreen

    # A typical xterm-256color terminal.
    XTERM = new ANSI.flags | Capability::Color256 | Capability::BrightColors |
                Capability::Italic | Capability::Faint | Capability::Strike |
                Capability::Conceal | Capability::EraseChars

    # A current terminal such as kitty, ghostty, or WezTerm.
    MODERN = new XTERM.flags | Capability::TrueColor | Capability::ExtendedUnderline |
                 Capability::UnderlineColor | Capability::Overline |
                 Capability::RapidBlink | Capability::SynchronizedOutput |
                 Capability::BracketedPaste | Capability::FocusEvents |
                 Capability::MouseSgr | Capability::Osc8Links | Capability::Titles |
                 Capability::CursorShape
  end
end
