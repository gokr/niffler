/* The narration track: the script of the movie, one cue per scene.
 *
 * This file is the SINGLE SOURCE for three consumers, which is why it is data
 * and not prose buried in the animation code:
 *   1. the captions on screen (always on, accessibility),
 *   2. the browser-voice preview (`?voice=browser`, speechSynthesis),
 *   3. tools/render-voiceover.mjs, which renders each cue to audio/<id>.mp3
 *      with a real TTS voice and writes audio/narration.json with the MEASURED
 *      duration of each line.
 *
 * `seconds` is the authored MINIMUM a scene holds, not a hard length: in
 * `?voice=track` mode a scene lasts max(seconds, audioSeconds + 0.45), so
 * re-recording a line never desynchronizes the picture from the voice.
 *
 * Writing rules kept deliberately: one idea per cue, ~28-34 words (≈11-13 s at
 * a measured 155 wpm), numbers stay concrete, no line depends on the previous
 * one being heard perfectly.
 */
window.NARRATION = [
  {
    id: "s1",
    seconds: 14,
    text: "Every coding agent claims to be different. This one is built on a bet: a harness should be small, and the agent should be able to extend it. This is Niffler."
  },
  {
    id: "s2",
    seconds: 15,
    text: "The usual shape is a monolith. One program, dozens of tools, and every schema shipped in every prompt. It works, until you want to change what the agent can do. Then you patch the monolith."
  },
  {
    id: "s3",
    seconds: 14,
    text: "Niffler starts from the other end. Its core is tiny, and it speaks exactly one thing: JSON envelopes over a message bus. No plugins loaded into the core. No core code linked into anything."
  },
  {
    id: "s4",
    seconds: 14,
    text: "Every capability is its own process. Bash. Edit. Grep. Git. A language server. A store. They are peers on the bus, and they come and go while the conversation keeps running."
  },
  {
    id: "s5",
    seconds: 19,
    text: "And here is the part that matters. When the agent needs a capability it does not have, it writes a component, builds it, and spawns it. Mid-conversation. The harness extends itself, and the agent doing it is the proof the architecture holds."
  },
  {
    id: "s6",
    seconds: 13,
    text: "One conversation is one process. Turns never nest inside a conversation, so a long job cannot corrupt its own history. And separate conversations never block each other."
  },
  {
    id: "s7",
    seconds: 13,
    text: "New capabilities do not rewrite the prompt. The prefix stays frozen and cached, while discovery hands the model one small tool at a time, exactly when it asks."
  },
  {
    id: "s8",
    seconds: 15.5,
    text: "Failure is designed, not hoped for. Two conversations writing one file are arbitrated by a lease that names its holder. A tool result lost to an outage is repaired when the history loads, not fatal forever."
  },
  {
    id: "s9",
    seconds: 12,
    text: "The wire is a hundred lines of runtime data, mirrored in Nim, Go, and TypeScript. Write a component in the language that fits the job."
  },
  {
    id: "s10",
    seconds: 11,
    text: "Small core. Real processes. A harness that extends itself. Niffler. Simple and fast, batteries included."
  }
];
