require "./capability"
require "./quirk"

module TermBuf
  # Stability: internal
  #
  # Guesses what a terminal can do from the environment it was started in.
  #
  # This runs before anything is written to the terminal, and it is all a
  # non-interactive session ever gets. It is deliberately pessimistic: a name
  # nobody recognises comes back with nothing, because a screen full of escape
  # sequences is worse than plain text.
  #
  # Probing runs afterwards and overrides whatever this decided, so being wrong
  # here costs accuracy only where a terminal cannot be asked directly.
  module EnvironmentDetector
    extend self

    # What kitty and its imitators add on top of a current terminal.
    KITTY_EXTRAS = Capability::KittyGraphics | Capability::KittyKeyboard |
                   Capability::KittyColorStack

    # Blinking text, which some current terminals parse and then ignore.
    #
    # There is no query for this and terminfo is no help: ghostty's own entry
    # declares `blink=\E[5m` and nothing on screen blinks. An attribute that
    # is inert rather than harmful is exactly the kind nobody bothers to
    # report accurately, so the only evidence is having looked.
    BLINKING = Capability::Blink | Capability::RapidBlink

    # The kitty colour stack, which ghostty parses and then does nothing with.
    #
    # There is no query for this either: `CSI # R` goes unanswered. The only
    # evidence is having watched it, and it was — against ghostty 1.3.2, an OSC
    # 11 read back after a push, a set, and a pop gives the value that was set,
    # not the one that was pushed. Without a working pop a colour change cannot
    # be given back, which is the whole reason `ColorStack` is gated on this
    # flag; claiming it wrongly leaves a terminal recoloured after the program
    # has exited.
    COLOR_STACK = Capability::KittyColorStack

    # Writing the system clipboard with OSC 52.
    #
    # A table entry rather than a measurement: OSC 52 answers nothing on a
    # write, so there is no query and no probe, only the terminal's
    # documentation and its source. Kitty, ghostty, WezTerm and foot all
    # document the write, and all four ship it enabled; xterm supports it and
    # ships it *off*, which is indistinguishable from not having it, so it
    # stays out. `TERMBUF_CAPS=+osc52_clipboard` covers a terminal that has it
    # and is not named here.
    CLIPBOARD_WRITE = Capability::Osc52Clipboard

    # What kitty does not draw.
    #
    # Measured against 0.48.2: SGR 53 leaves the text unmarked where SGR 4
    # underlines it, and SGR 8 leaves it visible. Kitty's own terminfo agrees,
    # declaring `blink` and `smxx` and neither an overline nor `invis` — where
    # ghostty's declares `invis=\E[8m`. Ghostty, WezTerm and foot draw both, so
    # they stay in `Capabilities::MODERN` and come off the one terminal by name.
    KITTY_MISSING = Capability::Overline | Capability::Conceal

    # kitty, whose protocols the other current terminals borrowed, less the two
    # attributes it does not draw.
    KITTY = (Capabilities::MODERN.flags | KITTY_EXTRAS | CLIPBOARD_WRITE) & ~KITTY_MISSING

    # A current terminal that neither blinks nor keeps colours for you.
    # `Capabilities.normalize` drops the rapid variant along with the slow one,
    # so taking both off here is belt and braces.
    GHOSTTY = (Capabilities::MODERN.flags | KITTY_EXTRAS | CLIPBOARD_WRITE) &
              ~(BLINKING | COLOR_STACK)

    # WezTerm, which took kitty's graphics protocol and not the rest of it.
    WEZTERM = Capabilities::MODERN.flags | Capability::KittyGraphics | CLIPBOARD_WRITE

    # foot, a current terminal with no protocols borrowed from kitty.
    FOOT = Capabilities::MODERN.flags | CLIPBOARD_WRITE

    # Matched against `TERM`, most specific first.
    TERM_PATTERNS = [
      {/\Adumb/, Capability::None},
      {/kitty/, KITTY},
      {/ghostty/, GHOSTTY},
      {/wezterm/, WEZTERM},
      {/alacritty/, Capabilities::MODERN.flags},
      {/\Afoot/, FOOT},
      {/\Acontour/, Capabilities::MODERN.flags},
      {/\Ario/, Capabilities::MODERN.flags},
      {/(256color|direct)/, Capabilities::XTERM.flags},
      {/\A(xterm|screen|tmux|rxvt|vte|gnome|konsole|st|ansi|linux|putty|eterm)/,
       Capabilities::ANSI.flags},
      {/\Avt(2|3|4|5)\d\d/, Capabilities::ANSI.flags},
      {/\Avt100/, Capability::Bold | Capability::Underline | Capability::Reverse |
                  Capability::Blink | Capability::ScrollRegion | Capability::AltScreen},
    ]

    # Matched against `TERM_PROGRAM`. These beat the `TERM` guess, since the
    # terminal names itself here rather than naming its terminfo entry.
    PROGRAM_PATTERNS = [
      {"ghostty", GHOSTTY},
      {"WezTerm", WEZTERM},
      # iTerm2 blinks, behind a per-profile `Blink Allowed` that ships off. That
      # is the user's setting rather than the terminal's ceiling, and a
      # capability describes what the terminal can be asked to do.
      {"iTerm.app", Capabilities::MODERN.flags},
      {"vscode", Capabilities::MODERN.flags},
      {"Hyper", Capabilities::XTERM.flags | Capability::TrueColor},
      {"rio", Capabilities::MODERN.flags},
      {"alacritty", Capabilities::MODERN.flags},
      # Terminal.app 470.2, measured: a smooth 24 bit ramp, bracketed paste,
      # blink, and conceal, but SGR 9 draws no line through anything. The
      # colour depth depends on the version; see `APPLE_TERMINAL_TRUECOLOR`.
      {"Apple_Terminal", Capabilities::XTERM.flags | Capability::TrueColor |
                         Capability::BracketedPaste},
    ]

    # Set by a terminal that has no `TERM_PROGRAM` of its own, or as well as
    # one. Each carries the name of the terminal that sets it, so a marker
    # inherited from whatever opened the window can be told from one the
    # terminal reading the output set itself.
    MARKER_VARIABLES = [
      {"KITTY_WINDOW_ID", "kitty", KITTY},
      {"GHOSTTY_RESOURCES_DIR", "ghostty", GHOSTTY},
      {"WEZTERM_PANE", "wezterm", WEZTERM},
      {"WEZTERM_EXECUTABLE", "wezterm", WEZTERM},
      {"ALACRITTY_WINDOW_ID", "alacritty", Capabilities::MODERN.flags},
      {"KONSOLE_VERSION", "konsole", Capabilities::XTERM.flags | Capability::TrueColor |
                                     Capability::Osc8Links},
      {"ITERM_SESSION_ID", "iterm", Capabilities::MODERN.flags},
    ]

    # A multiplexer sits between the application and the terminal and does not
    # forward everything. The kitty protocols in particular are swallowed,
    # so they come off until a probe says otherwise.
    THROUGH_MULTIPLEXER = KITTY_EXTRAS | Capability::KittyGraphicsTempFile |
                          Capability::SynchronizedOutput

    # Guesses from `TERM`, `TERM_PROGRAM`, `COLORTERM`, `VTE_VERSION`, and the
    # marker variables terminals set for themselves.
    def detect(env : Hash(String, String)) : Capabilities
      # A terminal that says it is dumb is taken at its word. Nothing else in
      # the environment gets a say, since anything that follows would only be
      # inherited from whatever launched it.
      return Capabilities::NONE if dumb? env

      flags = from_term env["TERM"]?
      flags |= from_program env
      flags |= from_markers env
      flags |= from_colorterm env
      flags |= from_vte env

      flags &= ~denied(env)
      flags &= ~THROUGH_MULTIPLEXER if multiplexed? env
      flags = strip_color flags if no_color? env

      Capabilities.new flags
    end

    # Capabilities a name is known not to imply, however much the rest of the
    # environment says otherwise.
    #
    # Separate from the pattern tables because composition is additive: under
    # ghostty with a `TERM` of `xterm-256color`, the xterm entry would put
    # blink back after the ghostty entry left it out, and the `256color`
    # pattern puts strike-through back on Terminal.app. A name that identifies
    # the terminal outranks one that only describes a family.
    DENIALS = [
      {"ghostty", BLINKING | COLOR_STACK},
      # kitty takes SGR 53 and SGR 8 and draws the text unchanged.
      {"kitty", KITTY_MISSING},
      # Terminal.app takes SGR 9 and draws the text unchanged.
      {"apple_terminal", Capability::Strike},
    ]

    # :ditto:
    def denials(name : String?) : Capability
      return Capability::None unless name

      lowered = name.downcase
      flags = Capability::None

      DENIALS.each do |(candidate, denied)|
        flags |= denied if lowered.includes? candidate
      end

      flags
    end

    # Terminals that get a grapheme cluster's column count wrong, matched
    # against the terminal that names itself the way `PROGRAM_PATTERNS` is. A
    # terminal has to be measured before it goes in here; see `Quirk`.
    QUIRK_PATTERNS = [
      {"apple_terminal", Quirk::PerCodePointColumns},
    ]

    # What the terminal in *env* is known to get wrong.
    def quirks(env : Hash(String, String)) : Quirk
      named = identified env
      return Quirk::None unless named

      flags = Quirk::None

      QUIRK_PATTERNS.each do |(candidate, quirk)|
        flags |= quirk if named.includes? candidate
      end

      flags
    end

    # The Terminal.app that shipped with macOS Tahoe. Earlier ones take a 24
    # bit colour and quantize it to the palette.
    APPLE_TERMINAL_TRUECOLOR = 464

    private def denied(env : Hash(String, String)) : Capability
      flags = denials(env["TERM"]?) | denials(identified(env))
      flags |= Capability::TrueColor if palette_only_terminal_app? env
      flags
    end

    # Whether this is a Terminal.app from before 24 bit colour.
    #
    # Asking would be better, and there is nothing to ask: Terminal.app answers
    # neither `DECRQSS` for SGR, nor `XTGETTCAP`, nor `DECRPM`. It replies to
    # the primary and secondary device attributes and to a cursor position
    # report, and to nothing else. So the version it puts in the environment is
    # all there is, and a version that is missing or unreadable is treated as
    # too old rather than assumed to be new.
    private def palette_only_terminal_app?(env : Hash(String, String)) : Bool
      return false unless program_name(env) == "apple_terminal"

      major = env["TERM_PROGRAM_VERSION"]?.try(&.split('.').first?).try &.to_i?
      major.nil? || major < APPLE_TERMINAL_TRUECOLOR
    end

    # Which terminal is reading the output, as far as the environment says.
    #
    # `TERM_PROGRAM` wins, because a terminal writing its own name there is
    # saying what it is; a marker variable naming something else was inherited
    # from whatever opened the window and describes a terminal that is no
    # longer in the picture. With no `TERM_PROGRAM`, a marker is the best name
    # there is.
    private def identified(env : Hash(String, String)) : String?
      program = program_name env
      return program if program

      MARKER_VARIABLES.each do |(variable, terminal, _)|
        return terminal if present? env, variable
      end

      nil
    end

    # The `TERM_PROGRAM` entry this environment matches, by the name the table
    # knows it as.
    private def program_name(env : Hash(String, String)) : String?
      name = env["TERM_PROGRAM"]?
      return unless name

      PROGRAM_PATTERNS.each do |(candidate, _)|
        return candidate.downcase if name.compare(candidate, case_insensitive: true).zero?
      end

      nil
    end

    private def dumb?(env : Hash(String, String)) : Bool
      term = env["TERM"]?
      return false unless term

      term.starts_with?("dumb") || term == "unknown"
    end

    private def from_term(term : String?) : Capability
      return Capability::None unless term

      TERM_PATTERNS.each do |(pattern, flags)|
        return flags if pattern.matches? term
      end

      Capability::None
    end

    private def from_program(env : Hash(String, String)) : Capability
      name = env["TERM_PROGRAM"]?
      return Capability::None unless name

      PROGRAM_PATTERNS.each do |(candidate, flags)|
        return flags if name.compare(candidate, case_insensitive: true).zero?
      end

      Capability::None
    end

    # Marker variables, less any that name a terminal other than the one
    # reading the output. Starting Terminal.app from a shell that had ghostty's
    # environment leaves `GHOSTTY_RESOURCES_DIR` set, and taking that at face
    # value hands Terminal.app the kitty graphics protocol.
    private def from_markers(env : Hash(String, String)) : Capability
      named = identified env
      flags = Capability::None

      MARKER_VARIABLES.each do |(variable, terminal, capability)|
        next unless present? env, variable
        next if named && !named.includes?(terminal)

        flags |= capability
      end

      flags
    end

    private def from_colorterm(env : Hash(String, String)) : Capability
      value = env["COLORTERM"]?
      return Capability::None unless value
      return Capability::TrueColor if value.in? "truecolor", "24bit"

      Capability::None
    end

    # VTE gained 24 bit colour in 0.36 and hyperlinks in 0.50.
    private def from_vte(env : Hash(String, String)) : Capability
      version = env["VTE_VERSION"]?.try(&.to_i?)
      return Capability::None unless version

      flags = Capability::None
      flags |= Capabilities::XTERM.flags | Capability::TrueColor if version >= 3600
      flags |= Capability::Osc8Links if version >= 5000
      flags
    end

    private def multiplexed?(env : Hash(String, String)) : Bool
      return true if present? env, "TMUX"
      return true if present? env, "STY"

      term = env["TERM"]?
      return false unless term

      term.starts_with?("screen") || term.starts_with?("tmux")
    end

    # The `NO_COLOR` convention: set to anything non-empty, and colour goes.
    private def no_color?(env : Hash(String, String)) : Bool
      present? env, "NO_COLOR"
    end

    private def strip_color(flags : Capability) : Capability
      flags & ~(Capability::Color16 | Capability::Color256 | Capability::TrueColor |
                Capability::BrightColors | Capability::UnderlineColor)
    end

    private def present?(env : Hash(String, String), name : String) : Bool
      value = env[name]?
      !value.nil? && !value.empty?
    end
  end
end
