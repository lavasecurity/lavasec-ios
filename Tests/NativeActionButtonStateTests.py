#!/usr/bin/env python3
"""Execute the production native action resolver with symbolic palette I/O.

No SwiftUI rendering, simulator, account, or service is used. The resolver is
extracted unchanged; the color double identifies which canonical semantic token
it selects, including platform pressed fill. Geometry/Dynamic Type contracts live
in LavaActionButtonSourceTests and AccessibilityLargeTextSourceTests.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'LavaSecApp/LavaDesignSystem/LavaScaffold.swift').read_text()
start = source.index('struct LavaFullWidthActionState {')
end = source.index('/// All native full-width actions', start)
resolver = source[start:end]
stubs = '''
import Foundation
struct UIColor { static let tertiarySystemFill = UIColor() }
struct Color: Equatable {
    let name: String
    init(_ name: String) { self.name = name }
    init(uiColor: UIColor) { self.name = "tertiarySystemFill" }
    static let black = Color("black")
}
enum LavaStyle {
    static let secondaryText = Color("secondaryText")
    static let actionForeground = Color("actionForeground")
    static let panelActionGreen = Color("panelActionGreen")
    static let primaryText = Color("primaryText")
    static let disabledSurface = Color("disabledSurface")
    static let safeControlGreen = Color("safeControlGreen")
    static let panelActionPressedFill = Color("panelActionPressedFill")
    static let panelActionFill = Color("panelActionFill")
    static let cardBackground = Color("cardBackground")
}
'''
tests = r'''
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    precondition(condition(), message)
}
let roles: [(LavaFullWidthActionState.Role, Color, Color, Color, Color, Double)] = [
    (.primary, .init("actionForeground"), .init("safeControlGreen"), .init("safeControlGreen"), .black, 0.10),
    (.panel, .init("panelActionGreen"), .init("panelActionFill"), .init("panelActionPressedFill"), .init("tertiarySystemFill"), 1),
    (.secondary, .init("primaryText"), .init("cardBackground"), .init("cardBackground"), .init("tertiarySystemFill"), 1)
]
check(roles.count == LavaFullWidthActionState.Role.allCases.count, "Every action role must be exercised")
for (role, foreground, fill, pressedFill, overlay, opacity) in roles {
    for enabled in [true, false] {
        for pressed in [true, false] {
            let state = LavaFullWidthActionState(role: role, isEnabled: enabled, isPressed: pressed)
            let activePress = enabled && pressed
            check(state.isEnabled == enabled, "The owner preserves native enabled state")
            check(state.isPressed == activePress, "Disabled actions must not be pressed")
            check(state.foreground == (enabled ? foreground : .init("secondaryText")), "All disabled action labels share readable secondary text")
            check(state.fill == (enabled ? (pressed ? pressedFill : fill) : .init("disabledSurface")), "Each role preserves its enabled/pressed fill and the common disabled surface")
            check(state.pressedOverlay == overlay, "Native pressed material remains role-specific")
            check(state.pressedOverlayOpacity == (activePress ? opacity : 0), "Disabled/unpressed actions show no pressed overlay")
            check(state.scale == (activePress ? 0.99 : 1), "Only enabled pressed actions scale")
        }
    }
}
print("Native action button states: \(assertions) executable assertions passed")
'''
with tempfile.TemporaryDirectory(prefix='lava-action-button-states-') as temporary:
    directory = Path(temporary)
    swift = directory / 'main.swift'
    swift.write_text(stubs + resolver + tests)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'module-cache'),
                    str(swift), '-o', str(directory / 'checks')], check=True, cwd=ROOT)
    subprocess.run([str(directory / 'checks')], check=True, cwd=ROOT)
