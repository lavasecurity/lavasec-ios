import type {LavaIconAction,LavaToolbarAction} from '../../contracts';

// Exact existing iOS artwork. Shared callers select purpose, never an SF name.
export const actionSymbols = {remove:'minus',delete:'trash',undo:'arrow.uturn.backward',reset:'arrow.counterclockwise',back:'chevron.left',close:'xmark',notes:'pencil',assist:'eye',hide:'eye.slash',refresh:'arrow.triangle.2.circlepath',erase:'eraser',confirm:'checkmark',edit:'square.and.pencil',add:'plus',share:'square.and.arrow.up',import:'square.and.arrow.down',automatic:'moon',play:'play.fill',pause:'pause.fill',previous:'backward.end.fill',next:'forward.end.fill',calendar:'calendar',swap:'arrow.up.arrow.down',twoPeople:'person.2',browse:'safari',passkey:'person.badge.key.fill',restoreBackup:'icloud.and.arrow.down'} as const satisfies Record<LavaIconAction,string>;

export const toolbarSymbols={'chevron.left':'back',xmark:'close',checkmark:'confirm',trash:'delete','square.and.pencil':'edit',moon:'automatic','arrow.clockwise':'refresh','arrow.triangle.2.circlepath':'refresh','arrow.counterclockwise':'reset',plus:'add','square.and.arrow.up':'share','square.and.arrow.down':'import',calendar:'calendar',pencil:'notes',eye:'assist','eye.slash':'hide','arrow.uturn.backward':'undo'} as const satisfies Readonly<Record<string,LavaIconAction>>;

// Refresh-now uses a different existing glyph from the ordinary refresh action.
export const toolbarActionSymbols = {
  back:'chevron.left',close:'xmark',confirm:'checkmark',delete:'trash',edit:'square.and.pencil',
  automatic:'moon',reload:'arrow.clockwise',refresh:'arrow.triangle.2.circlepath',reset:'arrow.counterclockwise',
  add:'plus',share:'square.and.arrow.up',import:'square.and.arrow.down',calendar:'calendar',
  notes:'pencil',assist:'eye',hide:'eye.slash',undo:'arrow.uturn.backward',
} as const satisfies Record<LavaToolbarAction,keyof typeof toolbarSymbols>;
