# gaze development guide

This file defines the working rules for every person or coding agent contributing to **gaze**. The product name is always displayed as `gaze`, including at the start of a sentence. Internal identifiers may follow the conventions required by their programming language or platform.

## Product boundary

gaze is a desktop-first music client targeting Linux, Windows, and macOS. Nobara Linux is the active development and testing platform. Windows and macOS support must be included architecturally but must not be described as tested until builds run on those operating systems. Its first server is Jellyfin running on an Unraid server. A separate mobile application may be built later, but mobile constraints must not weaken the desktop experience.

The desktop interface should combine artwork-led polish and purposeful animation with familiar, easy-to-understand music organization. It must have its own identity and must not reproduce Apple Music or Spotify screens. Design for monitors, mouse, keyboard, and touch displays; do not build a phone layout enlarged to fill a monitor.

Long-term capabilities include library browsing, search, favorites, playlists, a persistent player, Now Playing, a queue, lyrics, Jellyfin synchronization, MPRIS, and DeskStrip integration. These are goals, not permission to add all of them in an early phase.

## Required working practices

- Keep each task small, focused, and independently testable.
- Explain important technical choices in plain language suitable for a beginner.
- Never say a change was tested unless the stated command was actually run.
- Do not install system packages or use `sudo` without first explaining the exact package, reason, and impact and receiving approval.
- Do not initialize a framework, generate placeholder application code, or add a dependency unless the current task requires it.
- Do not remove or replace working behavior without first creating a Git checkpoint. If Git is unavailable or unhealthy, stop and explain the problem.
- Preserve unrelated user changes. Inspect repository status before editing.
- Prefer complete, maintainable files over temporary fragments.
- Add dependencies only when they provide clear value that is not practical to implement with the existing stack.
- Record major architecture and product decisions in documentation before or alongside implementation.
- Never commit secrets, Jellyfin credentials, server tokens, personal server addresses, generated build output, or cached media.

## Architecture boundaries

- Desktop widgets, window behavior, keyboard shortcuts, pointer interactions, and desktop navigation belong only to the desktop application.
- Domain models and use cases must not import Flutter, platform APIs, HTTP clients, databases, or Jellyfin-specific response models.
- Jellyfin transport and response parsing sit behind repository interfaces. Jellyfin objects must be translated into gaze domain models at the boundary.
- Playback sits behind a small application-facing interface. UI code must not call a media engine directly.
- Persistence and artwork caching are infrastructure concerns accessed through interfaces, not global utilities used from widgets.
- Linux MPRIS, Windows media sessions, macOS Now Playing, and future DeskStrip support are independent adapters that observe playback state and submit commands through the same playback controller used by the UI.
- Shared packages may support a future mobile client, but desktop-only behavior must not leak into shared packages.
- Keep authentication tokens in an OS credential store when that work is implemented; ordinary preferences and databases are not secret stores.
- Check every future dependency for maintained Linux, Windows, and macOS support before adoption, and document any platform-specific runtime requirements.

## Quality expectations

- Define the acceptance check before making a substantive change.
- Use formatting, static analysis, unit tests, and targeted integration or widget tests appropriate to the changed layer.
- Keep network and media-engine behavior replaceable in tests with fakes.
- Treat accessibility, keyboard navigation, focus visibility, reduced motion, responsive desktop widths, and touch target size as core design requirements.
- Test failure and offline states, not only successful server responses.
- Prefer structured logging that excludes credentials and sensitive URLs.

## Manual UI review rule

Whenever a task creates or changes anything visible in the gaze interface:

1. Run the automated checks first:
   - `dart format .`
   - `flutter analyze`
   - `flutter test`
   - `flutter build linux --debug`
2. Do not consider the UI task complete based only on automated tests.
3. After the checks pass, attempt to launch gaze with `flutter run -d linux`.
4. If the execution environment cannot display the graphical window, clearly state that limitation and give the user this exact normal-Konsole command: `cd /home/user/Projects/gaze && flutter run -d linux`.
5. Tell the user which refresh procedure applies:
   - For ordinary Dart and widget changes, press `r` in the active Flutter terminal to hot reload.
   - For dependency, plugin, runner, or native changes, stop the app with `Ctrl+C` and launch it again.
6. Stop before committing any meaningful visual change unless the user has manually inspected and approved the result.
7. Ask the user to provide:
   - A screenshot
   - What looks wrong
   - What feels unintuitive
   - Any animation, sizing, spacing, scrolling, or interaction feedback
8. After the user approves the visible result, create the requested Git checkpoint.
9. Never claim that a UI looks correct merely because it compiled or launched.

## Starting a development session

1. Read `README.md`, `PROJECT_PLAN.md`, `DESIGN_DIRECTION.md`, and this file.
2. Inspect `git status` and recent history. Do not overwrite existing work.
3. Confirm the current phase and choose one small task with a clear completion check.
4. Check the relevant tools and dependencies without installing anything automatically.
5. Implement only that task, run its checks, and report exactly what changed and what remains.
