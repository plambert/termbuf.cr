require "./capability"
require "./environment"
require "./overrides"
require "./prober"

module TermBuf
  # Stability: internal
  #
  # Settles what the terminal can do, in four stages, each overriding the one
  # before it:
  #
  # 1. a baseline of nothing at all;
  # 2. what the environment suggests;
  # 3. what the terminal says when asked directly;
  # 4. whatever `TERMBUF_CAPS` insists on.
  #
  # Probing is skipped when there is nothing to probe — output that is not a
  # terminal, or a caller that did not supply one. That is not an error: the
  # environment heuristics stand on their own, and a program writing to a pipe
  # still needs a capability set.
  module CapabilityResolver
    extend self

    # What the four stages settled on, plus what turned up along the way.
    record Result,
      capabilities : Capabilities,
      # Keystrokes that arrived while probing, to be handed to the decoder
      # rather than dropped.
      input : Bytes,
      # Problems worth telling the application about. These never go to
      # stderr: the screen is about to be taken over, and writing to it would
      # corrupt the display.
      warnings : Array(String),
      # What the terminal called itself, when it was asked and answered.
      name : String?,
      # Whether the terminal answered anything at all.
      probed : Bool,
      # What this terminal is known to get wrong. See `Quirk`.
      quirks : Quirk

    # Runs the four stages. Probes only when both *input* and *output* are
    # given.
    def resolve(env : Hash(String, String) = ENV.to_h,
                input : IO? = nil,
                output : IO? = nil,
                timeout : Time::Span = Prober::DEFAULT_TIMEOUT) : Result
      detected = EnvironmentDetector.detect env
      name = nil.as(String?)
      keystrokes = Bytes.empty
      probed = false

      if input && output
        probe = Prober.new(input, output, timeout).probe detected
        detected = probe.capabilities
        keystrokes = probe.input
        name = probe.name
        probed = !probe.answered.empty?
      end

      overridden = CapabilityOverrides.apply detected, env
      quirks = QuirkOverrides.apply EnvironmentDetector.quirks(env), env

      Result.new overridden.capabilities, keystrokes,
        overridden.warnings + quirks.warnings, name, probed, quirks.quirks
    end
  end
end
