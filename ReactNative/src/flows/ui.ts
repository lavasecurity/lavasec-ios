// Android supplies ui.android.ts using the same semantic component contract.
// A missing platform mapping must fail visibly instead of importing iOS native specs.
function unavailable():never {throw new Error('Flow UI requires this platform’s component adapter.');}
export const Copy:typeof import('./ui.ios').Copy=unavailable;
export const Section:typeof import('./ui.ios').Section=unavailable;
export const Choice:typeof import('./ui.ios').Choice=unavailable;
export const Symbol:typeof import('./ui.ios').Symbol=unavailable;
export const RowAccessory:typeof import('./ui.ios').RowAccessory=unavailable;
export const Group:typeof import('./ui.ios').Group=unavailable;
export const Info:typeof import('./ui.ios').Info=unavailable;
export const ListRow:typeof import('./ui.ios').ListRow=unavailable;
export const Panel:typeof import('./ui.ios').Panel=unavailable;
export const Search:typeof import('./ui.ios').Search=unavailable;
export const Toggle:typeof import('./ui.ios').Toggle=unavailable;
export const FlowSheet:typeof import('./ui.ios').FlowSheet=unavailable;
export const FormDivider:typeof import('./ui.ios').FormDivider=unavailable;
export const FormField:typeof import('./ui.ios').FormField=unavailable;
export const FormPanel:typeof import('./ui.ios').FormPanel=unavailable;
export const FormParagraph:typeof import('./ui.ios').FormParagraph=unavailable;
export const useCrossFadePreference:typeof import('./ui.ios').useCrossFadePreference=unavailable;
export const SystemButton:typeof import('./ui.ios').SystemButton=unavailable;
export const BufferedInput:typeof import('./ui.ios').BufferedInput=unavailable;
export const InlineSymbolText:typeof import('./ui.ios').InlineSymbolText=unavailable;
