import {useContext,useMemo,type PropsWithChildren} from 'react';
import {Platform} from 'react-native';
import {WindowMetricsContext} from '../src/window-layout';
import {PresentationContext} from '../app/presentation';

/** Native task parity is local to migrated iOS flows; Dynamic Type stays owned
 * by PresentationContext and each platform text/credential atom. */
export function NativeFlowMetrics({children}:PropsWithChildren){
  const base=useContext(PresentationContext);
  const presentation=useMemo(()=>{
    if(Platform.OS!=='ios')return base;
    const textScales={...base.textScales};let measured=false;
    for(const [ramp,size] of [['title1',28],['body',17],['headline',17],['subheadline',15],['footnote',13]] as const){
      const metric=base.nativeTextMetrics?.[ramp];
      if(metric&&Number.isFinite(metric.fontSize)&&metric.fontSize>0&&Number.isFinite(metric.lineHeight)&&metric.lineHeight>0&&Number.isFinite(metric.leading)&&metric.lineHeight+metric.leading>0){
        // UIFontMetrics.scaledValue(100) can round differently from the actual
        // semantic font. Match its point size for text and measured leaf atoms.
        textScales[ramp]=metric.fontSize/size;measured=true;
      }
    }
    return measured?{...base,textScales}:base;
  },[base]);
  return <WindowMetricsContext.Provider value="nativeFlow"><PresentationContext.Provider value={presentation}>{children}</PresentationContext.Provider></WindowMetricsContext.Provider>;
}
