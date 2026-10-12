# React Native window layout

`ReactNative/src/window-layout.ts` owns the larger-window sizing baseline. It
uses the current app window, not the device model or the physical orientation.
Native sheets scope that policy to their own measured viewport, including the
footer rendered by UIKit outside the route subtree. RN foreground forms measure
their existing keyboard-avoidance root, so a portrait-shaped native sheet uses
portrait form composition even inside a landscape app window.

The iPhone composition is the reference in each orientation. Portrait Guard
places Protection above the Today/current-filter pair and Explore below it.
Landscape can place the primary and secondary lanes alongside each other.
A portrait-shaped tablet window keeps the portrait composition. Accessibility
text can stack the lanes or the summary pair when needed.

The baseline stays at 1 through a 480-point short side, then grows smoothly to a
maximum of 1.4. Using the short side keeps phone sizing stable through rotation
and returns narrow tablet windows to phone sizing. This baseline multiplies the
user's semantic text ramps; it does not cap their accessibility setting.
Shared control targets and illustrations follow the geometry baseline.
Authored offsets and translations scale with their dependent dimensions. Flex ratios, percentage
widths, runtime measured coordinates and border strokes do not scale.
Reading pages are capped at 880 points; landscape story columns can use 1180.
Single-column Explore uses the reading band on larger windows, aligning its
panel edges with Filters and other reading pages. The shared `Screen` scaffold's
`wide="compact"` policy preserves its existing breadth on phone-sized windows
in either orientation; it does not change the scene or its controls.
Content determines panel height, and the page keeps its existing scroll owner.

Shared scaffolds use separate bounded curves for typography/control geometry,
panel insets and gaps. All start at the phone baseline through a 480-point
short side and reach their maximum at 960 points: 1.4 for type/geometry, 1.8 for
insets, and 1.75 for gaps. A 20-point story-panel inset becomes 36 points;
a 16-point panel gap becomes 28. Negative interaction margins follow their
paired padding. Story, settings, reading/detail, activity, row and sheet owners
share this policy; their adopters do not invent screen-specific adjustments.
Geometry-bound illustrations, connection rails and Sudoku retain the uniform
geometry scale so authored offsets stay attached to their nodes.
Sudoku's portrait height budget scales its feedback and bottom clearance while
retaining the measured horizontal keypad band; the same budget controls scrolling.

The shared page clearance grows from 16 to 24 points below the native header.
There is no Guard-specific top-padding exception or vertical centering. The
page keeps the normal native header frame, direct scroll root and content-driven
panel height. Horizontal page gutters keep their existing geometry curve and
content caps; native title alignment uses that same edge. Sheets continue to
size themselves and their detached footers from their measured viewport.

Short native utility flows use a separate presentation size, rather than the
page's wide reading band. Import remains the existing SwiftUI flow hosted above
RN. The flow declares the shared utility sizing policy. Its UIKit host opts
into a 640-point preferred form width when the actual
presenting window has a short side above 480 points. `LavaSheetScaffold` reports
its natural scroll content and pinned controls through a shared preference;
the host adds the measured native navigation bar height and supplies both
dimensions through `preferredContentSize`. The native form sheet owns centering,
keyboard adjustment and dismissal, without a custom height detent. Measurements
are coalesced after SwiftUI layout. Width and height are bounded to 85% of the
presenting window, with a natural height floor of 320 points before that cap.
Longer stages and accessibility text retain their existing scroll owner.
Compact app windows keep the full native sheet. The components, native titles,
stage transitions, keyboard handling and dismissal owners are unchanged.

The shared `Screen` publishes its centered panel edge to the native navigation
header on larger windows. The pinned native-stack header adapter forwards this
public layout metric to `UINavigationBar.directionalLayoutMargins`; UIKit still
owns the large title, its collapse and bar items. Reading and wide pages use
their respective content caps. Compact windows and inline destinations restore
the system margin. Preparation checks all dependency owners before changing any
file, rejects dependency drift and is idempotent.

`Text responsive={false}` preserves geometry-derived type, such as Sudoku cell
numbers and reveal artwork. Ordinary copy uses the shared responsive baseline.
`Symbol responsive={false}` is used when its caller already supplies the combined
text scale, so the tablet baseline is applied once.

The component tests cover tablet and compact-window sizing, orientation changes,
accessibility composition, retained drafts and native-sheet/footer sizing. The
real-Yoga regression also preserves the first native resize frame before a JS
window-dimension event. `RNWindowLayoutUITests` captures the complete app across
rotation and at the largest accessibility text size; render receipts belong in
private review evidence.
