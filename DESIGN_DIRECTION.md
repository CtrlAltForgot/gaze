# gaze design direction

## Design promise

gaze should feel calm, premium, modern, and deeply connected to the listener's artwork. It aims for the craft, motion, and presentation quality people associate with Apple Music and the organizational clarity familiar to Spotify, while developing an original visual language for a Linux desktop. These products are quality references, not templates to copy.

The interface should explain itself through hierarchy, placement, feedback, and familiar music concepts. It should feel composed rather than sparse: generous where artwork and focus benefit, compact where scanning and queue management benefit.

## Desktop-first composition

- Use a stable left navigation region, a flexible central content canvas, a persistent bottom playback region, and an optional right queue region when width permits.
- Let wide monitors reveal useful context rather than merely stretching cards or adding empty margins.
- Use denser rows for track lists and queues, and more generous compositions for discovery, albums, artists, and Now Playing.
- Support precise pointer interactions, visible keyboard focus, shortcuts, context menus, hover feedback, drag-and-drop, and touch targets large enough for touch displays.
- Adapt deliberately at narrower desktop widths: collapse secondary regions before compromising the primary task. Do not imitate phone navigation on an ordinary desktop window.

## Visual language

- Artwork is the strongest color and emotional signal. Present it sharply, preserve its proportions, and avoid covering important imagery with controls.
- Use artwork-derived color as a restrained atmosphere—gradients, soft fields, or accents—while maintaining predictable contrast and readable text.
- Preserve the artwork's approximate color proportions in that atmosphere: dominant colors should own most of the field, while small details remain small moving accents rather than taking over the interface.
- Establish a neutral foundation with a small semantic accent system. Avoid a permanently loud interface that competes with album art.
- Use typography to make page identity, metadata, actions, and supporting information immediately distinguishable. Track tables remain readable at desktop density.
- Use consistent spacing, corner shapes, dividers, overlays, and elevation. Every exception needs a functional reason.
- Use blur and translucency sparingly and only when performance and contrast remain reliable on Linux hardware.
- Keep the name `gaze` lowercase in all displayed text.

## Motion and feedback

- Animation should preserve context: artwork can transition into Now Playing, panels can reveal their origin, and queue changes can visibly settle into place.
- Prefer short, responsive transitions for controls and navigation; reserve slower cinematic motion for infrequent, artwork-focused moments.
- Never delay a common action to show animation. Input feedback must be immediate.
- Allow extremely slow artwork-derived ambient background movement while music is active, so the current album can own the visual atmosphere without making controls or content move. Keep it calm, freeze it under reduced motion, and avoid unrelated decorative animation.
- Respect reduced-motion settings with simpler fades or immediate state changes.
- Define loading, buffering, disabled, success, and failure feedback consistently.

## Interaction principles

- The current track, playback state, and primary action should always be unambiguous.
- Common actions should be discoverable without instructions; advanced actions may live in context menus and shortcuts but should also have visible routes.
- Preserve scroll position and navigation context when moving between library levels.
- Make destructive playlist or queue actions clear and recoverable where practical.
- Keep queue manipulation direct and predictable, especially during drag-and-drop.
- Treat loading, empty, offline, permission, and server-error states as designed screens, not afterthoughts.

## Accessibility and consistency

- Maintain readable contrast even when artwork colors are difficult.
- Provide visible focus, logical traversal order, semantic labels, scalable text, non-color status cues, and sufficiently large targets.
- Make hover an enhancement, never the only way to discover an essential action.
- Apply the same components and behavior across Home, album, artist, search, playlists, favorites, queue, and Now Playing.
- Validate the design on real Nobara desktop rendering, not only in static mockups.

## Originality guardrail

Do not recreate another service's exact navigation, icon arrangement, gradients, page structure, or signature interactions. For each major screen, start with the listener's task and gaze's desktop layout system. References may set the quality bar; gaze's hierarchy, proportions, motion, and details must form a coherent identity of their own.
