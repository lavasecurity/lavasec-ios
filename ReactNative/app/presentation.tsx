import {createContext, useContext, type ReactNode} from 'react';
import {Alert as NativeAlert, Text as NativeText, StyleSheet, type TextProps} from 'react-native';
import {translations} from './translations';
export type Presentation = {locale:string;textScales:Record<string,number>|null};
export const PresentationContext = createContext<Presentation>({locale:'en',textScales:null});
let locale = 'en';
export function configurePresentation(value?:Presentation) {locale=value?.locale??'en';}
// Tests observe lookups the native catalog lacks; production leaves this unset.
let missingTranslationObserver:((value:string)=>void)|undefined;
export function observeMissingTranslations(observer?:(value:string)=>void) {missingTranslationObserver=observer;}
export function localized(value:string):string {
  const table=translations[locale]??translations[locale.split('-')[0]!]??{};
  const translated=table[value];
  if(translated===undefined&&missingTranslationObserver&&value&&!(value in (translations.en??{})))missingTranslationObserver(value);
  return translated??value;
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
export function Text({verbatim=false,...props}:TextProps&{verbatim?:boolean}) {
  const {textScales}=useContext(PresentationContext);
  const style=StyleSheet.flatten(props.style);
  const scale=props.allowFontScaling!==false?textScales?.[props.dynamicTypeRamp??'body']:undefined;
  return <NativeText {...props} accessibilityLabel={props.accessibilityLabel?(verbatim?props.accessibilityLabel:localized(props.accessibilityLabel)):undefined}
    {...(scale===undefined?{}:{allowFontScaling:false,dynamicTypeRamp:undefined,style:[props.style,{fontSize:(style?.fontSize??17)*scale,...(style?.lineHeight?{lineHeight:style.lineHeight*scale}:{})}]})}>{verbatim?props.children:localizedChildren(props.children)}</NativeText>;
}
type AlertOptions=NonNullable<Parameters<typeof NativeAlert.alert>[3]>&{verbatimTitle?:boolean;verbatimMessage?:boolean};
export const Alert:{alert:(title:string,message?:string,buttons?:Parameters<typeof NativeAlert.alert>[2],options?:AlertOptions)=>void;prompt:typeof NativeAlert.prompt} = {
  alert:(title,message,buttons,options)=>{
    // Cancelled authorization or a revoked read epoch silently retires the action.
    if(message==='Authentication cancelled.'||message==='Read access changed.')return;
    const {verbatimTitle,verbatimMessage,...nativeOptions}=options??{};
    NativeAlert.alert(title&&!verbatimTitle?localized(title):title,message&&!verbatimMessage?localized(message):message,buttons?.map(button=>({...button,text:button.text?localized(button.text):button.text})),options?nativeOptions:undefined);
  },
  prompt:(title,message,callback,type,value,keyboard,options)=>NativeAlert.prompt(title?localized(title):title,message?localized(message):message,Array.isArray(callback)?callback.map(button=>({...button,text:button.text?localized(button.text):button.text})):callback,type,value,keyboard,options),
};
