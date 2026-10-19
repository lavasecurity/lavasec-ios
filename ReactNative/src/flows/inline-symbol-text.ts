import type {ColorValue} from 'react-native';

/** Portable inline glyph/text leaf; each platform supplies its native text run. */
export type InlineSymbolTextProps={title:string;symbol:string;tintColor:ColorValue;textColor:ColorValue;fontSize:number;fontWeight:'regular'|'semibold'|'bold';testID?:string};
