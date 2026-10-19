// Android supplies info-ui.android.ts for the same portable FlowInfo composition.
function unavailable():never {throw new Error('Flow UI requires this platform’s component adapter.');}
export const Copy:typeof import('./info-ui.ios').Copy=unavailable;
export const Panel:typeof import('./info-ui.ios').Panel=unavailable;
export const InlineSymbolText:typeof import('./info-ui.ios').InlineSymbolText=unavailable;
