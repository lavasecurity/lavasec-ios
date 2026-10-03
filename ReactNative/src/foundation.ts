import {lavaTokens} from './generated/tokens';

// Shared composition measurements. Platform colors and native typography are
// generated from LavaTokens.swift; screens select roles rather than inventing
// a new measurement for each occurrence of the same element.
export const foundation = {
  // UIKit reports its actual switch size after mounting. Reserve the same
  // initial footprint in list edit mode, before that measurement is available.
  nativeSwitch: {width:64,height:34},
  discovery: {dotSize: 8},
  outcome: lavaTokens.outcomeSymbols,
  symbol: lavaTokens.glyphSymbols,
  space: lavaTokens.spacing,
  fullSheet: lavaTokens.fullSheet,
  // `dimmedOpacity` recedes a control that is not the current subject without
  // hiding it. It is demo narration's treatment only: an ordinary tap selects,
  // and selection never dims the siblings it is chosen among (PR #724 follow-up).
  interaction: {pressedOpacity: 0.65, dimmedOpacity: 0.45},
  radius: {
    surface: lavaTokens.surface.cardCornerRadius,
    control: lavaTokens.surface.controlCornerRadius,
    compact: lavaTokens.surface.compactCornerRadius,
    circle: 999,
  },
  control: {target: lavaTokens.toolbar.buttonSize, glyph: lavaTokens.navigation.glyphPointSize, glyphSlot: lavaTokens.toolbar.iconFrameSize, accessory: lavaTokens.toolbar.buttonSize, accessoryGlyph: lavaTokens.navigation.accessoryPointSize},
  row: {...lavaTokens.row, gap: lavaTokens.spacing.md, metadataGap: lavaTokens.spacing.xs,
    // Disclosure marks aren't standalone targets. Reserve only the glyph, so
    // an invisible button-sized slot cannot inflate the visible trailing inset.
    disclosureWidth: lavaTokens.navigation.accessoryPointSize,
  },
  story: {gap: lavaTokens.spacing.lg, tileInset: lavaTokens.spacing.lg, summaryMinHeight: 116},
  layout: {
    readingWidth: 720, wideWidth: 1180, wideThreshold: 760, compactThreshold: 340, expandedSceneMinHeight: 500,
    // Apply only on the horizontal axis of a responsive composition. Explicit
    // width + auto basis makes Fabric/Yoga remeasure instead of reusing the
    // same mounted child's former vertical height as its horizontal flex basis.
    horizontalPart: {width: 0, flexGrow: 1, flexShrink: 1, minWidth: 0},
  },
  type: {
    title: {fontSize: 32, fontWeight: '700', dynamicTypeRamp: 'largeTitle'},
    heading: lavaTokens.typography.primaryValue,
    identityEmoji: {...lavaTokens.typography.primaryValue,fontSize:lavaTokens.filterIdentity.emojiPointSize},
    section: lavaTokens.typography.sectionLabel,
    fieldLabel: lavaTokens.typography.fieldLabel,
    body: {fontSize: 17, fontWeight: '400', dynamicTypeRamp: 'body'},
    row: lavaTokens.typography.rowTitle,
    supporting: lavaTokens.typography.rowMetadata,
    caption: {fontSize: 13, fontWeight: '400', dynamicTypeRamp: 'footnote'},
    metric: lavaTokens.typography.metricNumeral,
  },
} as const;
export type CopyRole = Exclude<keyof typeof foundation.type, 'metric'>;
