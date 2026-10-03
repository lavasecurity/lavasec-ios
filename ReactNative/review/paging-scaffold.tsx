import {useEffect,useRef,useState,type ReactNode} from 'react';
import {AppState,I18nManager,ScrollView,StyleSheet,View,type ScrollViewInstance} from 'react-native';
import {LavaChoice} from '../src';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors.ios';
import {localized} from '../app/presentation';
import {usePageInspectionLock} from './primitives';

// UIScrollView supplies paging physics; UIPageControl supplies native dots and
// accessibility adjustment. All pages remain mounted to retain in-card state.
export function PagedCards({label,pages}:{label:string;pages:readonly {id:string;title:string;content:ReactNode}[]}){
  const [width,setWidth]=useState(0);const [selected,setSelected]=useState(pages[0]?.id??'');
  const scroll=useRef<ScrollViewInstance>(null);const lock=usePageInspectionLock();
  const ordered=I18nManager.isRTL?[...pages].reverse():pages;
  const index=Math.max(0,ordered.findIndex(page=>page.id===selected));
  useEffect(()=>{if(width)scroll.current?.scrollTo({x:index*width,animated:false});},[width]);
  useEffect(()=>{if(!pages.some(page=>page.id===selected))setSelected(pages[0]?.id??'');},[pages,selected]);
  useEffect(()=>{const subscription=AppState.addEventListener('change',state=>{if(state!=='active')lock(false);});return()=>{subscription.remove();lock(false);};},[lock]);
  const select=(id:string)=>{const next=ordered.findIndex(page=>page.id===id);if(next<0)return;setSelected(id);scroll.current?.scrollTo({x:next*width,animated:true});};
  const settle=(offset:number)=>{lock(false);if(width){const page=ordered[Math.max(0,Math.min(ordered.length-1,Math.round(offset/width)))];if(page)setSelected(page.id);}};
  return <View testID="carousel.surface" style={styles.surface} onLayout={event=>setWidth(event.nativeEvent.layout.width)}>
    <ScrollView testID="carousel.scroll" ref={scroll} horizontal pagingEnabled directionalLockEnabled showsHorizontalScrollIndicator={false}
      style={{flexGrow:0,direction:'ltr'}} contentContainerStyle={{direction:'ltr',alignItems:'stretch'}}
      contentInsetAdjustmentBehavior="never" onScrollBeginDrag={()=>lock(true)}
      onScrollEndDrag={event=>settle(event.nativeEvent.targetContentOffset?.x??event.nativeEvent.contentOffset.x)}
      onTouchCancel={()=>lock(false)} onResponderTerminate={()=>lock(false)}
      onMomentumScrollEnd={event=>settle(event.nativeEvent.contentOffset.x)}>
      {width>0&&ordered.map(page=><View key={page.id} testID={`carousel.page.${page.id}`} style={{width,direction:I18nManager.isRTL?'rtl':'ltr',alignSelf:'stretch'}} accessibilityElementsHidden={selected!==page.id}
        importantForAccessibility={selected===page.id?'auto':'no-hide-descendants'}>{page.content}</View>)}
    </ScrollView>
    <View style={styles.indicator}><LavaChoice presentation="pages" label={localized(label)} testID="carousel.pages" value={selected}
      options={pages.map(page=>({value:page.id,label:localized(page.title)}))} onValueChange={select}/></View>
  </View>;
}
// Native horizontal layout measures every mounted page in the same pass. Its
// tallest intrinsic child determines the shared cross-axis frame; there is no
// cached/fixed height to clip a new translation or larger accessibility text.
const styles=StyleSheet.create({
  surface:{backgroundColor:colors.cardBackground,borderRadius:foundation.radius.surface,borderCurve:'continuous',overflow:'hidden'},
  indicator:{paddingHorizontal:foundation.space.lg,paddingBottom:foundation.space.lg},
});
