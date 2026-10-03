import SwiftUI
import UIKit
import LavaSecKit

private enum SudokuEasterEggLayout {
    /// Smallest board side the layout will render: 9 cells at a 33pt touch-target floor, so the
    /// clamp never sizes the board below usable. A screen band too short to host it scrolls (see
    /// `boardSide`) instead of shrinking the puzzle into a degenerate sliver.
    static let minBoardSide: CGFloat = 297
    static let keypadSpacing: CGFloat = 6
    static let keypadKeyHeight: CGFloat = 52
    static let eraserKeyHeight: CGFloat = 44
    /// Separate the destructive action from digit entry without moving the row or its magnifier.
    static let eraserDigitGap: CGFloat = 18
    static let keypadPreviewHeight: CGFloat = 76
    static let keypadPreviewWidth: CGFloat = 68
    /// Top bar (60) + correctness outcome slot (36) + number bar (140) + bottom inset (20).
    /// The eraser shares the preview lane, so showing it never shifts the board or digit row.
    static let verticalChromeHeight: CGFloat = 256
}

private enum SudokuKeypadKey: Equatable {
    case eraser
    case digit(Int)

    var slot: Int {
        switch self {
        case .eraser: -1
        case .digit(let digit): digit - 1
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .eraser: "Clear".lavaLocalized
        case .digit(let digit): "\(digit)"
        }
    }

    func remainingCount(in state: SudokuGameState?) -> Int {
        guard case .digit(let digit) = self else { return 0 }
        return state?.remainingCount(for: digit) ?? 9
    }
}

/// The hidden Sudoku easter egg: a full-screen, paper-style 9×9 board with no timer.
///
/// Entered by tapping the Guard hero mascot five times (see `ProtectionStatusPanel`). The board
/// resumes an in-progress game when the Lava Guard progress local-log toggle is on, gives a fresh
/// puzzle when none exists yet, and offers a refresh button for a new puzzle on demand. Givens are
/// bold and locked.
///
/// Input is touch-based and deliberately simple — there is no digit drag-to-place machinery:
/// - Tap a cell to select it (a full-strength ring marks the selection).
/// - Slide a finger across the board to track the selector with a light haptic at each cell boundary;
///   editable cells become the input target, while a locked clue gets a stronger grey treatment
///   and clears the input target.
/// - Press or scrub across the nine-slot bottom keypad to preview a magnified digit, with one light
///   haptic per key boundary; lifting commits the tracked digit.
/// - A short, wide eraser spans the 4-5-6 columns above the digits and appears only when the selected
///   editable cell contains a value. It is a direct action and never shows a preview bubble.
/// - The pencil toggles notes mode: saved notes are shown only while that mode is active, flowing
///   into a three-column grid that grows toward 3x3 as candidates accumulate, in grey italic type.
/// - The eye toggles assist feedback: remaining counts appear below the number keys, and a green
///   check or orange cross appears between the top bar and board for the selected filled cell.
///   User-entered digits are green with assistance off; with it on, correct entries stay green and
///   incorrect entries turn orange. Givens keep neutral ink on a light-grey locked background.
///
/// Completion is shown by the upper result glyph and BOARD BORDER: orange when all cells are filled but any is wrong
/// (still editable, "check your work"), green when all are correct (locked; the refresh glyph turns
/// green to hint at the next puzzle). A solved board is never auto-replaced.
struct SudokuEasterEggView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// A DEBUG-only launch route supplies this in UI tests so every run starts from the same clean
    /// board instead of resuming mutations left in a reused simulator container.
    private let initialPuzzleSeed: UInt64?

    @State private var gameState: SudokuGameState?
    @State private var selectedIndex: Int?
    @State private var trackingIndex: Int?
    @State private var isNotesMode = false
    @State private var showsCorrectness = false
    @State private var trackedKey: SudokuKeypadKey?
    @State private var isShowingResetConfirmation = false
    @State private var isShowingRefreshConfirmation = false

    init(initialPuzzleSeed: UInt64? = nil) {
        self.initialPuzzleSeed = initialPuzzleSeed
    }

    var body: some View {
        // One top-level GeometryReader sizes the board ONCE from the available screen band. The
        // explicit .frame(width: side, height: side) below ends the layout cycle cleanly (the prior
        // GeometryReader + aspectRatio + Spacer arrangement oscillated 81 cells every frame).
        GeometryReader { proxy in
            let side = boardSide(for: proxy.size)
            ZStack {
                LavaStyle.groupedBackground.ignoresSafeArea()

                // The ScrollView exists ONLY for bands shorter than board + chrome: `boardSide`
                // floors at `minBoardSide` there, and the scroll absorbs the overflow (Chrome
                // scrolls, the board never shrinks below its floor). On all normal screens the
                // content fits and there is nothing to scroll.
                ScrollView {
                    VStack(spacing: 0) {
                        topBar
                        correctnessOutcomeIndicator
                        boardView(side: side)
                        Spacer(minLength: 0)
                        numberBar
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    // Equal-and-opposite spacer: when the band is TALLER than the content, this
                    // stretches to v-center it; when it is shorter (clamped board), it collapses
                    // to zero and the ScrollView takes over.
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Sudoku owns its keypad. A passcode/system keyboard (including an inset retained across
        // sleep) must not reduce the GeometryReader's screen band and pin the board at its floor.
        // Ignore only keyboard space: the status bar and home-indicator safe areas still apply.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(nil)
        .task {
            loadOrStartPuzzle()
        }
        .lavaConfirmationAlert { host in
            host.alert("Reset puzzle?", isPresented: $isShowingResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetCurrentPuzzle()
                }
            } message: {
                Text("Your entries and notes will be removed. The puzzle will stay the same.")
            }
        }
        .lavaConfirmationAlert { host in
            host.alert("New puzzle", isPresented: $isShowingRefreshConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("New puzzle", role: .destructive) {
                    startFreshPuzzle()
                }
            } message: {
                Text("Your entries and notes will be removed and a new puzzle will begin.")
            }
        }
    }

    /// `true` only when the board is fully and correctly solved → digit entry and erasing lock,
    /// and the new-puzzle action turns green. Board selection and tracking remain available.
    private var boardIsLocked: Bool {
        gameState?.isSolved == true
    }

    /// `true` when the bottom number keys should accept a touch: a cell is selected, the board isn't
    /// solved, and (in notes mode) the selected cell is empty. Disabling otherwise keeps a gesture
    /// from previewing and then silently no-oping.
    private var canEnterDigit: Bool {
        guard !boardIsLocked, let selectedIndex, let gameState else { return false }
        if isNotesMode {
            return gameState.workingBoard[selectedIndex] == 0
        }
        return true
    }

    /// The eraser is a contextual action, never a persistent mode. Its preview-lane space stays
    /// reserved so the board and digits never jump when the selected cell becomes filled or empty.
    private var canEraseSelectedCell: Bool {
        guard !boardIsLocked, let selectedIndex, let gameState else { return false }
        return gameState.userValues[selectedIndex] != 0
    }

    /// The board border color reflects completion state: neutral while incomplete, orange when
    /// complete-but-wrong, green when solved.
    private var borderColor: Color {
        guard let gameState else { return LavaStyle.ink.opacity(0.85) }
        if gameState.isSolved { return LavaStyle.safeGreen }
        if gameState.isComplete { return LavaStyle.lavaOrange }
        return LavaStyle.ink.opacity(0.85)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            LavaIconActionButton(systemName: "chevron.left", accessibilityLabel: "Back") { dismiss() }

            Spacer()

            LavaToolbarModeButton(systemName: "pencil", isSelected: isNotesMode) {
                isNotesMode.toggle()
                ProtectionHapticFeedback.play(.selectionConfirmed)
            }
            .accessibilityIdentifier("sudoku-notes-toggle")
            .accessibilityLabel(isNotesMode ? "Notes mode on".lavaLocalized : "Notes mode off".lavaLocalized)

            LavaToolbarModeButton(
                systemName: showsCorrectness ? "eye" : "eye.slash",
                isSelected: showsCorrectness
            ) {
                showsCorrectness.toggle()
                ProtectionHapticFeedback.play(.selectionConfirmed)
            }
            .accessibilityIdentifier("sudoku-correctness-toggle")
            .accessibilityLabel(showsCorrectness
                ? "Puzzle assistance on".lavaLocalized
                : "Puzzle assistance off".lavaLocalized)

            LavaToolbarActionGroup {
                LavaToolbarIconButton(systemName: "arrow.counterclockwise", accessibilityLabel: "Reset") {
                    isShowingResetConfirmation = true
                    ProtectionHapticFeedback.play(.selectionConfirmed)
                }
                .accessibilityIdentifier("sudoku-reset")

                // Completion uses the prominent green treatment to point to the next-game action.
                LavaToolbarProminentActionButton(systemName: "plus", isProminent: boardIsLocked) {
                    isShowingRefreshConfirmation = true
                    ProtectionHapticFeedback.play(.selectionConfirmed)
                }
                .accessibilityIdentifier("sudoku-refresh")
                .accessibilityLabel("New puzzle".lavaLocalized)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    /// Correctness must not depend on color alone. While the eye is open, mirror the selected
    /// user-entered cell's result with a green check/orange cross glyph in the quiet space above
    /// the board. The fixed-height container prevents the puzzle from jumping as the glyph appears,
    /// changes, or disappears.
    private var correctnessOutcomeIndicator: some View {
        ZStack {
            if let isCorrect = correctnessOutcome {
                Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isCorrect ? LavaStyle.safeGreen : LavaStyle.lavaOrangeText)
                    .accessibilityIdentifier("sudoku-correctness-outcome")
                    .accessibilityLabel(gameState?.isComplete == true
                        ? (isCorrect ? "Puzzle solved".lavaLocalized : "Puzzle has errors".lavaLocalized)
                        : (isCorrect ? "Correctly placed".lavaLocalized : "Misplaced".lavaLocalized))
            }
        }
        .frame(minHeight: 36, maxHeight: .infinity)
    }

    /// Completion has precedence over optional selected-cell assistance.
    private var correctnessOutcome: Bool? {
        guard let gameState else { return nil }
        if gameState.isComplete { return gameState.isSolved }
        guard showsCorrectness,
              let selectedIndex,
              !gameState.isCellGiven(selectedIndex),
              gameState.userValues[selectedIndex] != 0 else { return nil }
        return gameState.userValues[selectedIndex] == gameState.puzzle.solution[selectedIndex]
    }

    // MARK: Board

    /// The board side is fixed from the screen size so layout settles in one pass (the prior
    /// GeometryReader+aspectRatio loop pinned the CPU). Horizontal padding accounts for the 16pt
    /// gutters, and the vertical budget leaves room for the top bar, correctness indicator, and
    /// number bar (`verticalChromeHeight`). Two clamps keep the board tappable on ANY band:
    /// `- 32`/the chrome subtraction can go NEGATIVE on short layouts (a negative `.frame` side
    /// collapses the board to nothing — tap-dead), and a band shorter than chrome+minimum would leave
    /// `min(...)` at a degenerate sliver, so the result is floored at `minBoardSide` and the
    /// ScrollView host absorbs the overflow by scrolling instead of shrinking the board below
    /// usability. On normal screens the clamps never bind and the side is exactly the
    /// pre-existing computation.
    private func boardSide(for size: CGSize) -> CGFloat {
        min(
            max(
                min(size.width - 32, size.height - SudokuEasterEggLayout.verticalChromeHeight),
                SudokuEasterEggLayout.minBoardSide
            ),
            size.width - 32
        )
    }

    private func boardView(side: CGFloat) -> some View {
        let cell = side / 9
        return ZStack(alignment: .topLeading) {
            if let gameState {
                gridCells(gameState: gameState, cellSize: cell)
                gridLines(side: side, cellSize: cell)
                    .allowsHitTesting(false)
                boardBorder(side: side)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        // Keep this gesture on the fixed side×side frame, before the outer centering frame, so its
        // local coordinates map directly to rows and columns in portrait and landscape. It runs
        // simultaneously with per-cell taps: a normal tap keeps the precise cell action, while a
        // moving finger advances the visible selector across cell boundaries.
        .simultaneousGesture(boardTrackingGesture(side: side))
        .frame(maxWidth: .infinity)
        // The border color is the completion signal, but color alone is invisible to VoiceOver.
        // Expose completion via an invisible announcement overlay (NOT .accessibilityElement(.combine),
        // which would collapse the 81 individual cell elements and make them unnavigable).
        .overlay(alignment: .top) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityElement()
                .accessibilityLabel(boardAccessibilityLabel)
                .accessibilityValue(boardAccessibilityValue)
        }
    }

    private var boardAccessibilityLabel: String {
        guard let gameState else { return "Sudoku board".lavaLocalized }
        if gameState.isSolved { return "Sudoku board, solved".lavaLocalized }
        if gameState.isComplete { return "Sudoku board, complete but with errors".lavaLocalized }
        return "Sudoku board".lavaLocalized
    }

    private var boardAccessibilityValue: String {
        guard let gameState else { return "" }
        let filled = gameState.workingBoard.lazy.filter { $0 != 0 }.count
        return "%lld of 81 cells filled".lavaLocalizedFormat(filled)
    }

    private func gridCells(gameState: SudokuGameState, cellSize: CGFloat) -> some View {
        let board = gameState.workingBoard
        return VStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { col in
                        let index = row * 9 + col
                        let isGiven = gameState.isCellGiven(index)
                        SudokuCellView(
                            value: board[index],
                            isGiven: isGiven,
                            showsCorrectness: showsCorrectness,
                            isCorrect: board[index] == gameState.puzzle.solution[index],
                            notes: gameState.notes[index],
                            showsNotes: isNotesMode,
                            isSelected: selectedIndex == index,
                            isTrackingLocked: trackingIndex == index && isGiven,
                            cellSize: cellSize
                        )
                        .frame(width: cellSize, height: cellSize)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleCellTap(index)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("sudoku-cell-\(index)")
                        .accessibilityLabel(cellAccessibilityLabel(for: index, in: gameState))
                        // Editable (non-given) cells are buttons: VoiceOver can activate them to
                        // select before placing via the number bar. Given cells are locked —
                        // activating them is a no-op.
                        .accessibilityAddTraits(gameState.isCellGiven(index) ? .isStaticText : .isButton)
                    }
                }
            }
        }
    }

    private func gridLines(side: CGFloat, cellSize: CGFloat) -> some View {
        Canvas { context, _ in
            var thin = Path()
            var thick = Path()
            for line in 1..<9 {
                let position = CGFloat(line) * cellSize
                if line % 3 == 0 {
                    thick.move(to: CGPoint(x: position, y: 0))
                    thick.addLine(to: CGPoint(x: position, y: side))
                    thick.move(to: CGPoint(x: 0, y: position))
                    thick.addLine(to: CGPoint(x: side, y: position))
                } else {
                    thin.move(to: CGPoint(x: position, y: 0))
                    thin.addLine(to: CGPoint(x: position, y: side))
                    thin.move(to: CGPoint(x: 0, y: position))
                    thin.addLine(to: CGPoint(x: side, y: position))
                }
            }
            context.stroke(thin, with: .color(LavaStyle.secondaryText.opacity(0.35)), lineWidth: 1)
            context.stroke(thick, with: .color(LavaStyle.ink.opacity(0.85)), lineWidth: 2.5)
        }
    }

    /// The outer completion border. Drawn as a stroked rounded rectangle in the state color, thick
    /// enough to read the orange/green signal clearly.
    private func boardBorder(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(borderColor, lineWidth: 3)
            .frame(width: side, height: side)
    }

    // MARK: Number bar

    private var keypadKeys: [SudokuKeypadKey] {
        (1...9).map(SudokuKeypadKey.digit)
    }

    private var numberBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let eraserWidth = SudokuEasterEggLayout.eraserKeyHeight
            let digitRowOffset = SudokuEasterEggLayout.keypadPreviewHeight
            ZStack(alignment: .topLeading) {
                eraserButton
                    .frame(width: eraserWidth, height: SudokuEasterEggLayout.eraserKeyHeight)
                    .position(
                        x: keypadKeyCenterX(forSlot: 4, totalWidth: width),
                        y: SudokuEasterEggLayout.keypadPreviewHeight
                            - SudokuEasterEggLayout.eraserDigitGap
                            - SudokuEasterEggLayout.eraserKeyHeight / 2
                    )
                    // The magnifier uses this same lane while scrubbing. Fade the eraser so its
                    // glyph never competes with the enlarged digit, and keep the bubble at the key.
                    .opacity(trackedKey == nil ? 1 : 0)

                HStack(spacing: SudokuEasterEggLayout.keypadSpacing) {
                    ForEach(keypadKeys, id: \.slot) { key in
                        keypadKeyView(key)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: SudokuEasterEggLayout.keypadKeyHeight)
                .offset(y: digitRowOffset)

                // Keep the nine native digit Buttons for accessibility, but route direct touch tracking
                // through one transparent surface. UIKit delivers touch-down, cross-key movement,
                // release, and cancellation without a SwiftUI DragGesture cancelling Button taps.
                SudokuKeypadTouchOverlay(
                    onChanged: { point in
                        if let point {
                            trackKeypadTouch(atX: point.x, totalWidth: width)
                        } else {
                            trackedKey = nil
                        }
                    },
                    onEnded: { point in
                        if let point {
                            trackKeypadTouch(atX: point.x, totalWidth: width)
                        }
                        finishKeypadTouch(commit: point != nil)
                    }
                )
                .frame(width: width, height: SudokuEasterEggLayout.keypadKeyHeight)
                .offset(y: digitRowOffset)
                .accessibilityHidden(true)

                if let trackedKey {
                    let anchor = keypadKeyCenterX(forSlot: trackedKey.slot, totalWidth: width)
                    let bubbleCenter = keypadBubbleCenterX(forKeyCenter: anchor, totalWidth: width)
                    SudokuKeyPreview(
                        key: trackedKey,
                        tailOffset: anchor - bubbleCenter
                    )
                    .position(x: bubbleCenter, y: SudokuEasterEggLayout.keypadPreviewHeight / 2)
                    .transition(.scale(scale: 0.86, anchor: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88), value: trackedKey)
            .frame(
                width: width,
                height: digitRowOffset + SudokuEasterEggLayout.keypadKeyHeight,
                alignment: .topLeading
            )
            .onAppear {
                ProtectionHapticFeedback.prepareSelectionChange()
            }
        }
        .frame(
            height: SudokuEasterEggLayout.keypadPreviewHeight
                + SudokuEasterEggLayout.keypadKeyHeight
        )
        .padding(.top, 12)
    }

    private var eraserButton: some View {
        Button {
            activateKey(.eraser)
        } label: {
            Image(systemName: "eraser")
                .font(.body.weight(.semibold))
                .foregroundStyle(LavaStyle.primaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Circle()
                        .fill(Color(uiColor: .secondarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .opacity(canEraseSelectedCell ? 1 : 0)
        .accessibilityIdentifier("sudoku-eraser")
        .accessibilityLabel("Clear".lavaLocalized)
        .accessibilityHint("Erase selected cell".lavaLocalized)
        .accessibilityHidden(!canEraseSelectedCell)
        .disabled(!canEraseSelectedCell)
    }

    @ViewBuilder
    private func keypadKeyView(_ key: SudokuKeypadKey) -> some View {
        let isAvailable = canActivateKey(key)
        let isTracked = trackedKey == key
        let isNoted = keyIsNoted(key)
        let isHighlighted = isTracked || isNoted
        let remaining = key.remainingCount(in: gameState)
        // Counts are informational, including zero: correctness belongs to the check/cross and
        // board border. Keep keys visually active while entry is allowed, so users can revise a
        // filled-but-wrong board without the assist toggle changing the rules of placement.

        Button {
            activateKey(key)
        } label: {
            Group {
                switch key {
                case .eraser:
                    Image(systemName: "eraser")
                        .font(.title3.weight(.semibold))
                case .digit(let digit):
                    VStack(spacing: 1) {
                        Text("\(digit)")
                            .font(.title2.bold())
                        if showsCorrectness {
                            Text("\(remaining)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : LavaStyle.secondaryText)
                        }
                    }
                }
            }
            .foregroundStyle(!isAvailable ? LavaStyle.secondaryText : isHighlighted ? Color.white : LavaStyle.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: SudokuEasterEggLayout.keypadKeyHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHighlighted ? LavaStyle.safeControlGreen : LavaStyle.cardBackground)
            )
        }
        .buttonStyle(LavaCondensedRowButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(keyAccessibilityIdentifier(key))
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(showsCorrectness ? "%lld remaining".lavaLocalizedFormat(remaining) : "")
        .accessibilityHint(keyAccessibilityHint(key))
        .accessibilityAddTraits(isNoted ? .isSelected : [])
        .disabled(!isAvailable)
    }

    private func keyIsNoted(_ key: SudokuKeypadKey) -> Bool {
        guard isNotesMode,
              case .digit(let digit) = key,
              let selectedIndex,
              let gameState,
              gameState.workingBoard[selectedIndex] == 0
        else { return false }
        return gameState.notes[selectedIndex].contains(digit)
    }

    private func canActivateKey(_ key: SudokuKeypadKey) -> Bool {
        switch key {
        case .eraser: canEraseSelectedCell
        case .digit: canEnterDigit
        }
    }

    private func keyAccessibilityIdentifier(_ key: SudokuKeypadKey) -> String {
        switch key {
        case .eraser: "sudoku-eraser"
        case .digit(let digit): "sudoku-digit-\(digit)"
        }
    }

    private func keyAccessibilityHint(_ key: SudokuKeypadKey) -> String {
        switch key {
        case .eraser:
            "Erase selected cell".lavaLocalized
        case .digit(let digit):
            isNotesMode
                ? "Toggles candidate %lld in the selected cell".lavaLocalizedFormat(digit)
                : "Places %lld in the selected cell".lavaLocalizedFormat(digit)
        }
    }

    // MARK: Actions

    /// Tracks a finger moving across the board. `minimumDistance` leaves ordinary taps to each
    /// cell's tap gesture; once movement begins, the selector follows the finger and emits one
    /// light haptic per newly entered cell (never continuously within the same cell).
    private func boardTrackingGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                trackCell(at: value.location, boardSide: side)
            }
            .onEnded { _ in
                trackingIndex = nil
            }
    }

    private func trackCell(at location: CGPoint, boardSide: CGFloat) {
        guard let index = cellIndex(at: location, boardSide: boardSide),
              trackingIndex != index,
              let gameState
        else {
            return
        }

        trackingIndex = index
        if gameState.isCellGiven(index) {
            // A locked clue can sit under the finger, but it must not leave a prior editable cell
            // looking active or accepting digit input. Its stronger grey treatment is supplied
            // by `isTrackingLocked`; editable tracking uses the normal green selection treatment.
            selectedIndex = nil
        } else {
            selectedIndex = index
        }
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    private func cellIndex(at location: CGPoint, boardSide: CGFloat) -> Int? {
        guard boardSide > 0,
              location.x >= 0, location.x < boardSide,
              location.y >= 0, location.y < boardSide
        else {
            return nil
        }

        let cellSide = boardSide / 9
        let column = Int(location.x / cellSide)
        let row = Int(location.y / cellSide)
        return row * 9 + column
    }

    /// Tracks a touch continuously across 1...9. Every newly entered available key gets a
    /// prepared selection tick and a magnified preview; lifting commits exactly the last tracked key.
    private func trackKeypadTouch(atX x: CGFloat, totalWidth: CGFloat) {
        guard let key = keypadKey(at: x, totalWidth: totalWidth), canActivateKey(key) else {
            trackedKey = nil
            return
        }
        guard trackedKey != key else { return }
        trackedKey = key
        ProtectionHapticFeedback.play(.selectionChanged)
    }

    private func finishKeypadTouch(commit: Bool) {
        let keyToCommit = trackedKey
        trackedKey = nil
        if commit, let keyToCommit {
            activateKey(keyToCommit)
        }
    }

    private func keypadKey(at x: CGFloat, totalWidth: CGFloat) -> SudokuKeypadKey? {
        guard totalWidth > 0, x >= 0, x < totalWidth else { return nil }
        let spacing = SudokuEasterEggLayout.keypadSpacing
        let keyWidth = (totalWidth - spacing * 8) / 9
        guard keyWidth > 0 else { return nil }
        // Add half a gap before dividing by the key pitch so a finger crossing the visual spacing
        // transitions at its midpoint instead of dropping the bubble between adjacent keys.
        let pitch = keyWidth + spacing
        let slot = min(max(Int((x + spacing / 2) / pitch), 0), 8)
        return .digit(slot + 1)
    }

    private func keypadKeyCenterX(forSlot slot: Int, totalWidth: CGFloat) -> CGFloat {
        let spacing = SudokuEasterEggLayout.keypadSpacing
        let keyWidth = (totalWidth - spacing * 8) / 9
        return CGFloat(slot) * (keyWidth + spacing) + keyWidth / 2
    }

    private func keypadSpanWidth(slotCount: Int, totalWidth: CGFloat) -> CGFloat {
        let spacing = SudokuEasterEggLayout.keypadSpacing
        let keyWidth = (totalWidth - spacing * 8) / 9
        return keyWidth * CGFloat(slotCount) + spacing * CGFloat(slotCount - 1)
    }

    private func keypadBubbleCenterX(forKeyCenter keyCenter: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let halfBubble = SudokuEasterEggLayout.keypadPreviewWidth / 2
        return min(max(keyCenter, halfBubble), totalWidth - halfBubble)
    }

    private func activateKey(_ key: SudokuKeypadKey) {
        guard canActivateKey(key) else { return }
        switch key {
        case .eraser:
            if let selectedIndex {
                eraseCell(at: selectedIndex)
            }
        case .digit(let digit):
            enterDigit(digit)
        }
    }

    private func loadOrStartPuzzle() {
        if let initialPuzzleSeed {
            gameState = viewModel.startFreshSudokuPuzzle(seed: initialPuzzleSeed)
        } else if let saved = viewModel.sudokuGameState {
            // A persisted SOLVED board is RESUMED as-is (no auto-new-game): the green border + green
            // refresh glyph signal completion and prompt the user to tap for the next puzzle.
            gameState = saved
        } else {
            // Only a missing puzzle (first entry) or an explicit refresh generates a new one.
            gameState = viewModel.startFreshSudokuPuzzle()
        }
        selectedIndex = nil
        trackingIndex = nil
        isNotesMode = false
        trackedKey = nil
    }

    /// Routes a board-cell tap to selection (the target of a subsequent digit, note, or eraser key).
    private func handleCellTap(_ index: Int) {
        selectCell(index)
    }

    private func selectCell(_ index: Int) {
        // Given cells are locked — selecting them would highlight an uneditable cell and enable the
        // digit controls that then silently no-op. Leave the selection unchanged when a given is
        // tapped (and clear the highlight if one was selected), but ACKNOWLEDGE the touch with a
        // rejection haptic: ~40 of 81 cells are givens, so a silent no-op here reads as the whole
        // board ignoring taps ("I can't even select a cell"). The haptic keeps givens obviously
        // locked rather than dead.
        guard let gameState, !gameState.isCellGiven(index) else {
            if selectedIndex != nil {
                selectedIndex = nil
            }
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }
        selectedIndex = index
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    private func enterDigit(_ digit: Int) {
        guard var state = gameState, let index = selectedIndex, !boardIsLocked else { return }
        let wasSolved = state.isSolved

        if isNotesMode {
            state.toggleNote(digit, at: index)
        } else {
            state.placeValue(digit, at: index)
        }

        gameState = state
        viewModel.persistSudokuGameState(state)
        ProtectionHapticFeedback.play(!wasSolved && state.isSolved ? .actionSucceeded : .selectionConfirmed)
    }

    /// Clears the value and candidate notes at `index`. Given cells are immutable (a no-op), and the
    /// board must not be solved (locked). Used by the contextual keypad eraser.
    private func eraseCell(at index: Int) {
        guard var state = gameState, !boardIsLocked, !state.isCellGiven(index) else { return }
        state.clearCell(at: index)
        gameState = state
        viewModel.persistSudokuGameState(state)
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    private func startFreshPuzzle() {
        gameState = viewModel.startFreshSudokuPuzzle()
        selectedIndex = nil
        trackingIndex = nil
        isNotesMode = false
        trackedKey = nil
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    private func resetCurrentPuzzle() {
        guard let puzzle = gameState?.puzzle else { return }
        let state = SudokuGameState(puzzle: puzzle)
        gameState = state
        viewModel.persistSudokuGameState(state)
        selectedIndex = nil
        trackingIndex = nil
        isNotesMode = false
        trackedKey = nil
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    // MARK: Accessibility

    private func cellAccessibilityLabel(for index: Int, in state: SudokuGameState) -> String {
        let row = (index / 9) + 1
        let col = (index % 9) + 1
        let board = state.workingBoard
        // Localized format keys (printf-style) so VoiceOver announcements honor the device locale.
        if board[index] != 0 {
            if state.isCellGiven(index) {
                return "Row %lld, column %lld: %lld, given".lavaLocalizedFormat(row, col, board[index])
            }
            let valueLabel = "Row %lld, column %lld: %lld".lavaLocalizedFormat(row, col, board[index])
            guard showsCorrectness else { return valueLabel }
            let placement = board[index] == state.puzzle.solution[index]
                ? "Correctly placed".lavaLocalized
                : "Misplaced".lavaLocalized
            return [valueLabel, placement].joined(separator: ", ")
        }
        let candidates = isNotesMode ? state.notes[index].sorted() : []
        if candidates.isEmpty {
            return "Row %lld, column %lld: empty".lavaLocalizedFormat(row, col)
        }
        let joined = candidates.map(String.init).joined(separator: " ")
        return "Row %lld, column %lld: notes %@".lavaLocalizedFormat(row, col, joined)
    }
}

// MARK: - Cell

/// One Sudoku cell: a bold neutral digit for givens, a colored regular-weight user value, or horizontally
/// squeezed candidate notes while pencil mode is active. The selected cell shows a full-strength
/// RING + fill. A cell holding visible notes but not selected gets its OWN soft-green tint (no ring),
/// so a noted cell is visibly "has candidates" without reading as the active selection.
private struct SudokuCellView: View {
    let value: Int
    let isGiven: Bool
    let showsCorrectness: Bool
    let isCorrect: Bool
    let notes: Set<Int>
    let showsNotes: Bool
    let isSelected: Bool
    let isTrackingLocked: Bool
    let cellSize: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(backgroundFill)
            content
        }
        // strokeBorder is inset within the cell frame, so adjacent rings never bleed into neighbors.
        .overlay(
            Rectangle()
                .strokeBorder(highlightRingColor, lineWidth: 2.5)
        )
    }

    /// Selected cells carry a `safeGreen` fill; givens carry a persistent light-grey fill and use a
    /// stronger grey while the finger tracks across them. Note-bearing cells carry `softGreen` (the
    /// app's soft/background green — pale in light mode, dark forest in dark mode) so the states stay
    /// distinct: a note cell reads as "has candidates", a selected cell as "active".
    private var backgroundFill: Color {
        if isSelected { return LavaStyle.safeGreen.opacity(0.24) }
        if isTrackingLocked { return LavaStyle.secondaryText.opacity(0.24) }
        if isGiven { return LavaStyle.secondaryText.opacity(0.10) }
        if showsNotes && value == 0 && !notes.isEmpty { return LavaStyle.softGreen }
        return Color.clear
    }

    /// `safeGreen` — NOT `safeControlGreen` — for the ring. The two tokens are identical in light
    /// mode, but dark-mode `safeControlGreen` is DARKER by design (it hosts white glyphs) and
    /// measures only ~2:1 as a thin stroke over the dark board + cell tint, below the 3:1 WCAG
    /// non-text target. `safeGreen`'s bright dark value clears ~6:1 there.
    private var highlightRingColor: Color {
        if isSelected { return LavaStyle.safeGreen }
        if isTrackingLocked { return LavaStyle.secondaryText.opacity(0.72) }
        return .clear
    }

    @ViewBuilder
    private var content: some View {
        if value != 0 {
            Text("\(value)")
                .font(.system(size: cellSize * 0.55, weight: isGiven ? .bold : .regular, design: .rounded))
                .foregroundStyle(valueColor)
        } else if showsNotes && !notes.isEmpty {
            SudokuNotesGrid(notes: notes, cellSize: cellSize)
        }
    }

    private var valueColor: Color {
        guard !isGiven else { return LavaStyle.ink }
        // Eye closed: green identifies the player's entries, without revealing correctness.
        // Eye open: color agrees with the check/cross and accessible correctness announcement.
        guard showsCorrectness else { return LavaStyle.safeGreen }
        return isCorrect ? LavaStyle.safeGreen : LavaStyle.lavaOrangeText
    }
}

/// Candidate digits flow into a grid capped at three columns, growing toward 3x3 as they accumulate
/// (`SudokuNotesGridLayout` owns the shape and size rules). A lone note stays as large as a committed
/// value; denser cells shrink each digit into its slot. A partial final row is centred under the full
/// rows above, and the pencil treatment stays grey italic.
private struct SudokuNotesGrid: View {
    let notes: Set<Int>
    let cellSize: CGFloat

    var body: some View {
        let rows = SudokuNotesGridLayout.rows(for: notes)
        let columns = SudokuNotesGridLayout.columnCount(forNoteCount: notes.count)
        let slotWidth = columns > 0 ? cellSize / CGFloat(columns) : cellSize
        let fontSize = cellSize * CGFloat(SudokuNotesGridLayout.fontSizeMultiple(forNoteCount: notes.count))

        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let row = rows[rowIndex]
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { digit in
                        Text("\(digit)")
                            .font(.system(size: fontSize, weight: .regular, design: .rounded).italic())
                            .foregroundStyle(LavaStyle.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: slotWidth, height: cellSize / CGFloat(rows.count))
                    }
                }
            }
        }
        .frame(width: cellSize, height: cellSize)
    }
}

// MARK: - Key preview

/// Keyboard-style magnifier shown while the finger scrubs over the keypad. At the two screen edges
/// the body shifts inward while the tail remains pointed at the real key center.
private struct SudokuKeyPreview: View {
    let key: SudokuKeypadKey
    let tailOffset: CGFloat

    var body: some View {
        VStack(spacing: -1) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LavaStyle.cardBackground)
                    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
                switch key {
                case .eraser:
                    Image(systemName: "eraser")
                        .font(.system(size: 28, weight: .semibold))
                case .digit(let digit):
                    Text("\(digit)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(LavaStyle.primaryText)
            .frame(
                width: SudokuEasterEggLayout.keypadPreviewWidth,
                height: SudokuEasterEggLayout.keypadPreviewHeight - 10
            )

            KeyPreviewTail()
                .fill(LavaStyle.cardBackground)
                .frame(width: 18, height: 10)
                .offset(x: tailOffset)
        }
    }
}

private struct KeyPreviewTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Keypad touch tracking

/// A transparent direct-touch surface over the visual keys. Native SwiftUI Buttons remain beneath
/// it as the accessibility elements; this view is deliberately hidden from the accessibility tree.
private struct SudokuKeypadTouchOverlay: UIViewRepresentable {
    let onChanged: (CGPoint?) -> Void
    let onEnded: (CGPoint?) -> Void

    func makeUIView(context: Context) -> SudokuKeypadTouchView {
        let view = SudokuKeypadTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: SudokuKeypadTouchView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

private final class SudokuKeypadTouchView: UIView {
    var onChanged: ((CGPoint?) -> Void)?
    var onEnded: ((CGPoint?) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(with: touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(with: touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onEnded?(inBoundsPoint(from: touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onEnded?(nil)
    }

    private func update(with touches: Set<UITouch>) {
        onChanged?(inBoundsPoint(from: touches))
    }

    /// UIKit continues delivering a tracked touch after it leaves this view. Treat that as a
    /// native control cancellation: clear the preview while outside and never commit on release.
    private func inBoundsPoint(from touches: Set<UITouch>) -> CGPoint? {
        guard let point = touches.first?.location(in: self), bounds.contains(point) else { return nil }
        return point
    }
}

#if DEBUG
#Preview {
    SudokuEasterEggView()
        .environmentObject(AppViewModel(loadVPNState: false))
}
#endif
