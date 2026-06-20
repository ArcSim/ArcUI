## 3.7.3

### New Features

- **Patch 12.1 Support**: ArcUI is now compatible with patch 12.1. That patch is brand new, so some new errors may show up there that did not happen before; please report anything you run into so it can be fixed quickly.
- **Share Castbar Across Characters**: Optional setting, off by default, that uses one castbar look on every character, starting from the castbar you already have set up, with each character keeping its own on-screen position unless you also share the position.
- **Castbar Import and Export**: Share your full castbar setup as a string and load it on another character, or bundle it into your bars export so colors, fonts, per-cast-type profiles, thresholds, and position travel together.
- **Import a Castbar as a Saved Skin**: When a shared string includes a castbar, the import lets you either replace your live castbar or save the incoming one as a named skin you can apply later.
- **Hide Blizzard Castbar**: Optional toggle, off by default, that hides the default Blizzard castbar, and turning it back on restores the bar without reloading.
- **Movable Spell Icon**: Optional setting, off by default, that lets you drag the castbar's spell icon to a custom position while the options panel is open, with a reset button to restore it.
- **Shorten Long Spell Names**: Optional setting, off by default, that trims spell names longer than a chosen length so they fit on the castbar.
- **Resource Bar Text Color by Value**: Optional, off by default: resource bar value text can change color based on how full the resource is, with up to four color zones plus a base color and a choice of Fill or Drain direction.

### Improvements

- **Lighter Casting Updates**: The castbar now listens only for your own casting events, reducing background work during play.

### Bug Fixes

- **Cooldown Display Stability**: Back-end fixes to make the cooldown display less likely to stop working partway through a dungeon or raid.
- **Cooldown Group Positioning**: Back-end improvements to cooldown group icon placement, to help reduce icons doubling up, overlapping, or leaving stray empty gaps after talent changes, when opening the options panel, or on login.
- **Castbar No Longer Lingers After a Failed Cast**: The castbar now correctly clears when a cast is rejected, queued, or fails instead of staying on screen.
