require "./capability"

module TermBuf
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

    # Matched against `TERM`, most specific first.
    TERM_PATTERNS = [
      {/\Adumb/, Capability::None},
      {/kitty/, Capabilities::MODERN.flags | KITTY_EXTRAS},
      {/ghostty/, Capabilities::MODERN.flags | KITTY_EXTRAS},
      {/wezterm/, Capabilities::MODERN.flags | Capability::KittyGraphics},
      {/alacritty/, Capabilities::MODERN.flags},
      {/\Afoot/, Capabilities::MODERN.flags},
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
      {"ghostty", Capabilities::MODERN.flags | KITTY_EXTRAS},
      {"WezTerm", Capabilities::MODERN.flags | Capability::KittyGraphics},
      {"iTerm.app", Capabilities::MODERN.flags},
      {"vscode", Capabilities::MODERN.flags},
      {"Hyper", Capabilities::XTERM.flags | Capability::TrueColor},
      {"rio", Capabilities::MODERN.flags},
      {"alacritty", Capabilities::MODERN.flags},
      # Terminal.app reaches the 256 colour palette and stops there.
      {"Apple_Terminal", Capabilities::XTERM.flags},
    ]

    # Set by a terminal that has no `TERM_PROGRAM` of its own.
    MARKER_VARIABLES = [
      {"KITTY_WINDOW_ID", Capabilities::MODERN.flags | KITTY_EXTRAS},
      {"GHOSTTY_RESOURCES_DIR", Capabilities::MODERN.flags | KITTY_EXTRAS},
      {"WEZTERM_PANE", Capabilities::MODERN.flags | Capability::KittyGraphics},
      {"WEZTERM_EXECUTABLE", Capabilities::MODERN.flags | Capability::KittyGraphics},
      {"ALACRITTY_WINDOW_ID", Capabilities::MODERN.flags},
      {"KONSOLE_VERSION", Capabilities::XTERM.flags | Capability::TrueColor |
                          Capability::Osc8Links},
      {"ITERM_SESSION_ID", Capabilities::MODERN.flags},
    ]

    # A multiplexer sits between the application and the terminal and does not
    # forward everything. The kitty protocols in particular are swallowed,
    # so they come off until a probe says otherwise.
    THROUGH_MULTIPLEXER = KITTY_EXTRAS | Capability::KittyGraphicsTempFile |
                          Capability::SynchronizedOutput

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

      flags &= ~THROUGH_MULTIPLEXER if multiplexed? env
      flags = strip_color flags if no_color? env

      Capabilities.new flags
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

    private def from_markers(env : Hash(String, String)) : Capability
      flags = Capability::None

      MARKER_VARIABLES.each do |(name, capability)|
        flags |= capability if present? env, name
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
