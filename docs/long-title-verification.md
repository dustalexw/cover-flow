# Long track titles — October 15, 2026

Local build 1.5.1 (23) preserves complete titles in wrapped album/queue rows and
uses a single wider album column when titles exceed the two-column allowance.
Compact player, Album View, Lyrics and preparation headers use a measured,
clipped scrolling title; short titles stay still. The full original title remains
available to tooltips and accessibility. Reduce Motion uses static text instead.
Changing the title or available width restarts scrolling at the beginning.

The full Swift suite passes: 73 tests, five environment-related skips, zero
failures. Four new cases cover short/invalid geometry, both readable endpoints,
constant speed and bounds for very long titles, and wide-row selection for long
classical, Unicode, multiline and unbroken titles.

An offscreen SwiftUI rendering confirms the compact title stays within its
assigned width, a short Album View title stays centered, and the complete sample
title wraps legibly. The universal build and deep signing verification pass.
Live playback-window animation and hover interaction still need a desktop check.

Desktop follow-up: play a long-titled track, resize the main player and Album View,
and verify scrolling reveals both ends without shifting controls. Check wrapped
album/queue titles and stable queue-row height when hovering Remove. Toggle Reduce
Motion, change tracks, and verify full-title tooltips and accessibility labels.
