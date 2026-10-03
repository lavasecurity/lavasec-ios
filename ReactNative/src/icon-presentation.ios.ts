import {lavaTokens} from './generated/tokens';
import type {LavaIconAction} from './contracts';

const metrics = lavaTokens.toolbar;
// Thin iOS mapping; optical sizes are generated from the native design authority.
export function iconPresentation(action: LavaIconAction) {
  const symbols: Record<LavaIconAction,string> = {
    remove:'minus', delete:'trash', undo:'arrow.uturn.backward', reset:'arrow.counterclockwise', back:'chevron.left',
    close:'xmark', notes:'pencil', assist:'eye', hide:'eye.slash',
    refresh:'arrow.triangle.2.circlepath', erase:'eraser', confirm:'checkmark',
    edit:'square.and.pencil', add:'plus', share:'square.and.arrow.up',
    import:'square.and.arrow.down', automatic:'moon', play:'play.fill',
    pause:'pause.fill', previous:'backward.end.fill', next:'forward.end.fill',
    calendar:'calendar', swap:'arrow.up.arrow.down', twoPeople:'person.2',
  };
  return symbolPresentation(symbols[action]);
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
