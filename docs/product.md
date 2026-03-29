# TrackBall Watch — Product Definition

## One-Line Definition

TrackBall Watch is a wearable-first, cross-device input platform that turns watches and mobile companions into practical pointer, keyboard-adjacent, and assistant-assisted input tools for desktops and other hosts.

## Product Thesis

Existing remote-input products usually stop at "phone as trackpad" or "watch as remote mouse". They are often useful for couch control, presentations, or occasional media tasks, but they rarely become serious daily input tools.

This product is aimed at a different target:

- input that is usable while typing
- pointer control that feels deliberate rather than gimmicky
- fast switching between hosts
- a path toward combining pointing, typing, dictation, and assistant support
- one input workflow spanning wearable, phone, keyboard, and desktop

The product is being built from the input layer upward, because that is the highest-risk and least commoditized part.

## Target Product

The target product is broader than an Apple Watch app.

It should become a global input system with these capabilities:

1. Wearable pointer input
   - precise cursor control
   - click / secondary click
   - scroll
   - drag
   - host switching

2. Keyboard-adjacent workflows
   - pair with an external keyboard through a mobile device or directly to a host
   - combine keyboard and wearable pointer into one portable workstation input setup
   - support a shared clipboard or shared input buffer across connected hosts

3. Voice and command input
   - short dictation from the wrist
   - command capture
   - correction and normalization before insertion or execution

4. Assistant-assisted workflows
   - validate ambiguous user input
   - propose corrected text
   - convert quick natural input into structured actions
   - create tasks, reminders, and calendar events from lightweight capture

## Current Stage

The project is in the development stage of the first product line:

- desktop host
- Apple iPhone companion
- Apple Watch client

The current engineering priority is:

- cursor precision
- stable movement mechanics
- predictable low-latency behavior
- correctness of core pointer interactions

The assistant, clipboard, keyboard-integration, and multi-client expansion layers are part of the product direction, but they are not the current real-time critical path.

## Differentiation

The intended differentiation is not:

- "another remote mouse"
- "another watch utility"
- "another AI voice notes app"

The intended differentiation is:

- better pointer mechanics from a wearable device
- one consistent input model across modes
- a realistic path from pointer control to full portable input workflows
- assistant behavior added where it helps, not where it destabilizes real-time control

## Product Boundary

The system should be understood as four layers:

1. Input transport
   - watch / phone / desktop connectivity
   - packet delivery
   - pairing

2. Input semantics
   - cursor motion
   - scroll
   - click
   - text capture
   - command capture

3. Assistant logic
   - correction
   - disambiguation
   - validation
   - structured extraction

4. Execution adapters
   - OS input injection
   - clipboard workflows
   - calendar / tasks
   - app-specific actions

This boundary is important. The input loop must remain deterministic. Assistant logic can be slower and probabilistic, but it must not break pointer behavior.

## Platform Direction

The Apple bundle is the current implementation, not the whole future platform.

The repository should grow toward:

- desktop host core
- Apple wearable/mobile client bundle
- future sibling clients for other watch ecosystems
- shared protocol, input model, and assistant contracts

That means the Apple Watch app is one client of the platform, not the final product identity by itself.

## Why This Direction Is Reasonable

Several adjacent markets already exist:

- remote mouse / remote keyboard apps
- wearable assistant apps
- clipboard-sync tools
- multi-device keyboards

But these categories are fragmented. They usually do not provide:

- strong wearable pointer mechanics
- one coherent workflow across pointer + keyboard + buffer + assistant
- a practical wearable-first input model for daily work

That is the gap this product is trying to fill.
