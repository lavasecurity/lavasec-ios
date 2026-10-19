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

Migrated iOS tasks opt into `NativeFlowMetrics` around their adapters. They retain
authored point geometry, insets and gaps with a multiplier of 1 and use their
actual viewport width instead of the story reading cap. Dynamic Type remains
active: public preferred-UIFont measurements supply semantic point sizes and
multiline leading, including negative leading at accessibility sizes. Explicit
paragraph metrics remain caller-owned. The inline symbol-and-text atom selects
the matching semantic headline font before measuring its wrapped run. These
policies are local to migrated iOS tasks; ordinary RN sizing and Android's
platform metrics retain their own owners.

The shared page clearance grows from 16 to 24 points below the native header.
There is no Guard-specific top-padding exception or vertical centering. The
page keeps the normal native header frame, direct scroll root and content-driven
panel height. Horizontal page gutters keep their existing geometry curve and
content caps; native title alignment uses that same edge. Sheets continue to
size themselves and their detached footers from their measured viewport.

Short utility tasks use a separate presentation size from the page's reading
band. RN owns every import stage inside the existing UIKit sheet. Its host uses
a preferred width of up to 640 points when the presenting window has a short
side above 480 points. `FlowSheet` measures natural scroll content and pinned
controls, excluding the native navigation bar, and the import adapter reports
the total through `foreground.layout`. The native owner admits only the current
flow and stage, so an outgoing stage cannot resize its successor. The host adds
the measured native bar height and supplies `preferredContentSize`.

The native form sheet owns centering, keyboard adjustment and dismissal, without
a custom height detent. Presentation-size updates are coalesced on the main
queue. Width and height are bounded to 85% of the presenting window, with a
natural height floor of 320 points before that cap. Import completion uses the
larger 85% height presentation. Longer stages and accessibility text keep the RN
scroll owner; compact app windows keep the full native sheet. Native chrome and
keyboard integration remain in the host, RN owns stage transitions, and native
session admission controls whether a stage may dismiss.

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
