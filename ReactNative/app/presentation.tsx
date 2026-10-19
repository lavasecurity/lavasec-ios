import {createContext, useContext, type ReactNode} from 'react';
import {Alert as NativeAlert, Text as NativeText, PixelRatio, Platform, StyleSheet, useWindowDimensions, type TextProps, type TextStyle} from 'react-native';
import {translations} from './translations';
import {WindowMetricsContext,useWindowLayout} from '../src/window-layout';
export type NativeTextMetric={fontSize:number;lineHeight:number;leading:number};
export type Presentation = {locale:string;textScales:Record<string,number>|null;nativeTextMetrics?:Record<string,NativeTextMetric>;
  nativeSymbolMetrics?:{searchClear?:{fontSize:number;width:number;height:number};passcodeLock?:{fontSize:number;width:number;height:number}}};
export const PresentationContext = createContext<Presentation>({locale:'en',textScales:null});
let locale = 'en';
export function configurePresentation(value?:Presentation) {locale=value?.locale??'en';}
function translationLocale(value:string):string {
  const parts=value.replace(/_/g,'-').toLowerCase().split('-');
  const supported=Object.keys(translations);
  for(let length=parts.length;length>0;length--) {
    const candidate=parts.slice(0,length).join('-');
    const match=supported.find(language=>language.toLowerCase()===candidate);
    if(match)return match;
  }
  // Native bundles normally send their resolved catalog language. Regional
  // language tags from other hosts must select the same supported script.
  if(parts[0]==='zh')return parts.includes('hant')||parts.some(part=>['tw','hk','mo'].includes(part))?'zh-Hant':'zh-Hans';
  if(parts[0]==='pt')return 'pt-BR';
  return 'en';
}
// Tests observe lookups the native catalog lacks; production leaves this unset.
let missingTranslationObserver:((value:string)=>void)|undefined;
export function observeMissingTranslations(observer?:(value:string)=>void) {missingTranslationObserver=observer;}
export function localized(value:string):string {
  const table=translations[translationLocale(locale)]??translations.en??{};
  const translated=table[value];
  if(translated===undefined&&missingTranslationObserver&&value&&!(value in (translations.en??{})))missingTranslationObserver(value);
  return translated??translations.en?.[value]??value;
}
export function localizedNumber(value:number):string {return value.toLocaleString(locale.replace(/_/g,'-'));}
// Native catalog object/integer placeholders, including positional forms. Select the
// translated format before inserting values so the catalog key stays intact.
export function localizedFormat(format:string,...values:(string|number)[]):string {
  let next=0;
  return localized(format).replace(/%%|%(?:(\d+)\$)?(?:@|(?:ll)?d)/g,(placeholder,index:string|undefined)=>
    placeholder==='%%'?'%':String(values[index===undefined?next++:Number(index)-1]??placeholder));
}
function localizedChildren(value:ReactNode):ReactNode {
  if(typeof value==='string')return localized(value);
  // JSX interpolation splits otherwise static sentences into adjacent strings.
  if(Array.isArray(value)&&value.every(x=>typeof x==='string'||typeof x==='number'))return localized(value.join(''));
  return value;
}
// Detached iOS27 SwiftUI measurements agree with preferred UIFont.lineHeight +
// leading for each additional line. First/last lines retain their natural box.
// These regular-size metrics are only a fallback for an older host/fixtures.
const nativeParagraphFonts:Record<string,NativeTextMetric>={
  title1:{fontSize:28,lineHeight:33.4140625,leading:.5859375},
  subheadline:{fontSize:15,lineHeight:17.900390625,leading:2.099609375},
  body:{fontSize:17,lineHeight:20.287109375,leading:1.712890625},
  headline:{fontSize:17,lineHeight:20.287109375,leading:1.712890625},
  footnote:{fontSize:13,lineHeight:15.513671875,leading:2.486328125},
};
function nativeParagraphStyle(presentation:Presentation,ramp:string,fontScale:number,style:TextStyle):TextStyle|undefined {
  const fallback=nativeParagraphFonts[ramp];
  if(!fallback||style.fontSize!==fallback.fontSize||style.lineHeight!==undefined||style.fontFamily||style.fontStyle==='italic')return;
  const projected=presentation.nativeTextMetrics?.[ramp];
  const metric=projected&&Number.isFinite(projected.fontSize)&&projected.fontSize>0&&Number.isFinite(projected.lineHeight)&&projected.lineHeight>0&&Number.isFinite(projected.leading)&&projected.lineHeight+projected.leading>0?projected:fallback;
  const nativeScale=metric.fontSize/fallback.fontSize;
  const actualScale=presentation.textScales?.[ramp]??(metric===projected?nativeScale:fontScale);
  const lineHeight=(metric.lineHeight+metric.leading)/nativeScale;
  const naturalHeight=Math.ceil(metric.lineHeight/nativeScale*actualScale*PixelRatio.get())/PixelRatio.get();
  const margin=(naturalHeight-lineHeight*actualScale)/2;
  // Insets belong to the caller. Add only the first/last-line compensation.
  const vertical=style.marginVertical??style.margin??0;
  const top=style.marginTop??vertical,bottom=style.marginBottom??vertical;
  return {lineHeight,...(top===0&&bottom===0?{marginVertical:margin}:{
    ...(typeof top==='number'?{marginTop:top+margin}:{}),...(typeof bottom==='number'?{marginBottom:bottom+margin}:{}),
  })};
}
export function Text({verbatim=false,responsive=true,...props}:TextProps&{verbatim?:boolean;responsive?:boolean}) {
  const presentation=useContext(PresentationContext);const {textScales}=presentation;
  const metrics=useContext(WindowMetricsContext);const {fontScale}=useWindowDimensions();
  const layout=useWindowLayout();const windowScale=responsive?layout.scale:1;
  const style=StyleSheet.flatten(props.style);
  const paragraph=Platform.OS==='ios'&&metrics==='nativeFlow'&&props.allowFontScaling!==false&&style?nativeParagraphStyle(presentation,props.dynamicTypeRamp??'body',fontScale,style):undefined;
  const nativeStyle=paragraph?[props.style,paragraph]:props.style;
  const lineHeight=paragraph?.lineHeight??style?.lineHeight;
  const scale=props.allowFontScaling!==false?textScales?.[props.dynamicTypeRamp??'body']:undefined;
  const sizedStyle=windowScale===1?nativeStyle:[nativeStyle,{fontSize:(style?.fontSize??17)*windowScale,...(lineHeight?{lineHeight:lineHeight*windowScale}:{})}];
  return <NativeText {...props} accessibilityLabel={props.accessibilityLabel?(verbatim?props.accessibilityLabel:localized(props.accessibilityLabel)):undefined}
    {...(paragraph&&props.lineBreakStrategyIOS===undefined?{lineBreakStrategyIOS:'standard'}:{})}
    style={sizedStyle}
    {...(scale===undefined?{}:{allowFontScaling:false,dynamicTypeRamp:undefined,style:[nativeStyle,{fontSize:(style?.fontSize??17)*scale*windowScale,...(lineHeight?{lineHeight:lineHeight*scale*windowScale}:{})}]})}>{verbatim?props.children:localizedChildren(props.children)}</NativeText>;
}
type AlertOptions=NonNullable<Parameters<typeof NativeAlert.alert>[3]>&{verbatimTitle?:boolean;verbatimMessage?:boolean};
export function isPresentationCancellation(message:string):boolean {
  return message==='Authentication cancelled.'||message==='Read access changed.';
}
export const Alert:{alert:(title:string,message?:string,buttons?:Parameters<typeof NativeAlert.alert>[2],options?:AlertOptions)=>void;prompt:typeof NativeAlert.prompt} = {
  alert:(title,message,buttons,options)=>{
    // Cancelled authorization or a revoked read epoch silently retires the action.
    if(message&&isPresentationCancellation(message))return;
    const {verbatimTitle,verbatimMessage,...nativeOptions}=options??{};
    NativeAlert.alert(title&&!verbatimTitle?localized(title):title,message&&!verbatimMessage?localized(message):message,buttons?.map(button=>({...button,text:button.text?localized(button.text):button.text})),options?nativeOptions:undefined);
  },
  prompt:(title,message,callback,type,value,keyboard,options)=>NativeAlert.prompt(title?localized(title):title,message?localized(message):message,Array.isArray(callback)?callback.map(button=>({...button,text:button.text?localized(button.text):button.text})):callback,type,value,keyboard,options),
};
