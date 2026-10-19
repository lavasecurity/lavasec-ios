import {actionSymbols} from './ui/platform/ios/icons';
import {lavaTokens} from './generated/tokens';
import type {LavaIconAction} from './contracts';

const metrics = lavaTokens.toolbar;
// Thin iOS mapping; optical sizes are generated from the native design authority.
export function iconPresentation(action: LavaIconAction) {
  return symbolPresentation(actionSymbols[action]);
}

/** Native toolbar and inline adapters consume the same optical symbol metrics. */
export function symbolPresentation(symbol: string) {
  const pointSize = symbol==='chevron.left'?metrics.chevronIconPointSize
    : symbol==='xmark'?metrics.xmarkIconPointSize
      : symbol==='plus'?metrics.plusIconPointSize
        : symbol==='checkmark'?metrics.checkmarkIconPointSize
          : symbol==='trash'?metrics.wideIconPointSize:metrics.framedIconPointSize;
  return {symbol,pointSize};
}
