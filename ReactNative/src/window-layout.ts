import {foundation} from './foundation';
import {createContext,useContext,useMemo} from 'react';
import {StyleSheet,useWindowDimensions,type ViewStyle} from 'react-native';

export type WindowSize={width:number;height:number};
// Native form sheets can be smaller than Dimensions.window. Their measured
// viewport scopes the same policy used by pages, including detached footers.
export const WindowSizeContext=createContext<WindowSize|null>(null);

export function windowLayout({width,height}:WindowSize){
  const shortSide=Math.min(width,height);
  // Phone rotation must not enlarge the phone UI. A narrow tablet window also
  // returns to phone sizing; full-size tablets get a bounded larger baseline.
  const expansion=Math.min(1,Math.max(0,(shortSide-480)/480));
  const scale=1+0.4*expansion;
  return {width,height,scale,spacingScale:1+0.75*expansion,insetScale:1+0.8*expansion,
    topPadding:foundation.space.screenTop+8*expansion,landscape:width>height,
    readingWidth:Math.min(880,720*scale),wideWidth:1180,
    gutter:foundation.space.screenHorizontal*scale};
}

export function useWindowLayout(){
  const window=useWindowDimensions();
  const viewport=useContext(WindowSizeContext);
  return windowLayout(viewport??window);
}

// Single-column scenes retain their authored compact-window breadth, but use
// the shared reading band on larger windows. Only column compositions need the
// wider tablet landscape band.
export function pageContentWidth(layout:ReturnType<typeof windowLayout>,wide:boolean|'compact'=false){
  const expanded=wide===true||(wide==='compact'&&layout.scale===1);
  return expanded&&layout.landscape?layout.wideWidth:expanded&&layout.scale===1?foundation.layout.wideWidth:layout.readingWidth;
}

// Page clearances grow less than panel interiors. UIKit keeps its own title
// position; roominess belongs within and between the scaffold's surfaces.
export function pageTopPadding(layout:ReturnType<typeof windowLayout>){
  return layout.topPadding;
}

// Keep the native large title on the same edge as centered RN panels. A phone
// or compact window retains UIKit's own margins and inline landscape behavior.
export function pageHeaderInset(layout:ReturnType<typeof windowLayout>,contentWidth:number){
  return layout.scale>1?Math.max(0,(layout.width-contentWidth)/2)+layout.gutter:-1;
}

const dimensions=new Set(['top','bottom','left','right','start','end','width','height','minWidth','minHeight','maxHeight',
  'padding','paddingHorizontal','paddingVertical','paddingTop','paddingBottom','paddingLeft','paddingRight','paddingStart','paddingEnd',
  'margin','marginHorizontal','marginVertical','marginTop','marginBottom','marginLeft','marginRight','marginStart','marginEnd',
  'gap','rowGap','columnGap','borderRadius','borderTopLeftRadius','borderTopRightRadius','borderBottomLeftRadius','borderBottomRightRadius']);

// Scale intrinsic control geometry and spacing, not flex ratios, percentages,
// runtime measured coordinates, border strokes or text. Authored offsets move
// and numeric translations move with their dependent dimensions. Text has its
// own Dynamic Type owner; animated transforms retain their runtime owner.
export function scaleWindowStyle<T extends object>(style:T,scale:number):T{
  if(scale===1)return style;
  return Object.fromEntries(Object.entries(style).map(([key,value])=>[key,
    dimensions.has(key)&&typeof value==='number'?value*scale:
      key==='transform'&&Array.isArray(value)?value.map(transform=>transform&&typeof transform==='object'
        ?Object.fromEntries(Object.entries(transform).map(([axis,offset])=>[axis,
          (axis==='translateX'||axis==='translateY')&&typeof offset==='number'?offset*scale:offset])):transform):
      key==='maxWidth'&&typeof value==='number'?Math.min(value*scale,value<=720?880:1180):value])) as T;
}

export function useWindowStyles<T extends Record<string,object>>(styles:T):T{
  return useScaledStyles(styles,false);
}

const insets=new Set(['padding','paddingHorizontal','paddingVertical','paddingTop','paddingBottom',
  'paddingLeft','paddingRight','paddingStart','paddingEnd','margin','marginHorizontal','marginVertical',
  'marginTop','marginBottom','marginLeft','marginRight','marginStart','marginEnd']);
const gaps=new Set(['gap','rowGap','columnGap']);

// Scaffolds share a roomier spacing curve while illustrations and measured
// game geometry retain the uniform scale above. Text still scales exactly once.
export function scaleScaffoldStyle<T extends object>(style:T,layout:ReturnType<typeof windowLayout>):T{
  const geometry=scaleWindowStyle(style,layout.scale);
  return Object.fromEntries(Object.entries(geometry).map(([key,value])=>{
    const authored=(style as Record<string,unknown>)[key];
    return [key,typeof authored==='number'&&insets.has(key)?authored*layout.insetScale:
      typeof authored==='number'&&gaps.has(key)?authored*layout.spacingScale:value];
  })) as T;
}

export function useScaffoldStyles<T extends Record<string,object>>(styles:T):T{
  return useScaledStyles(styles,true);
}

function useScaledStyles<T extends Record<string,object>>(styles:T,scaffold:boolean):T{
  const layout=useWindowLayout();
  return useMemo(()=>layout.scale===1?styles:Object.fromEntries(Object.entries(styles).map(([key,value])=>{
    const flat=StyleSheet.flatten(value as ViewStyle)??{};
    return [key,scaffold?scaleScaffoldStyle(flat,layout):scaleWindowStyle(flat,layout.scale)];
  })) as T,[styles,scaffold,layout.scale,layout.spacingScale,layout.insetScale]);
}
