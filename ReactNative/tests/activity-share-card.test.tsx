import {act,render,screen} from '@testing-library/react-native';
import {PixelRatio,StyleSheet} from 'react-native';
import {configurePresentation,localized,localizedFormat,localizedNumber,PresentationContext} from '../app/presentation';
import {translations} from '../app/translations';
import {ActivityShareCard,activityCardFrame,type ActivityShareCardContent} from '../review/ActivityShareCard';

const hidden={includeHiddenElements:true};
const content:ActivityShareCardContent={token:'activity-token',payload:'https://apps.apple.com/app/lava-security/id6778022110',moduleCount:33,
  chart:'counts',period:'custom',startLabel:'November 28, 2025',endLabel:'February 14, 2026',dateLabel:'November 28, 2025 – February 14, 2026',
  allowed:9876543210,blocked:1234567890,uptime:'1h',buckets:[{start:1,label:'Nov 28',allowed:9876543210,blocked:1234567890,available:true,partial:false}]};
afterEach(()=>{configurePresentation();jest.useRealTimers();jest.restoreAllMocks();});

test.each([1,2,3])('Activity shares a fixed 1080 × 1350 canvas at density %s without moving the chart for long data',density=>{
  jest.spyOn(PixelRatio,'get').mockReturnValue(density);
  const view=render(<ActivityShareCard content={content}/>);
  const surface=()=>screen.getByTestId('activity-share-card',hidden);
  expect(surface()).toHaveStyle({width:1080/density,height:1350/density});
  const chart=StyleSheet.flatten(screen.getByTestId('activity-share-chart',hidden).props.style);
  expect(chart.height).toBeCloseTo(activityCardFrame.chart.height*2.5/density);
  expect(screen.getByText('Get Lava and stay protected today',hidden)).toBeTruthy();
  view.rerender(<ActivityShareCard content={{...content,allowed:22152,blocked:6248,dateLabel:'Oct 12–18, 2026'}}/>);
  expect(StyleSheet.flatten(screen.getByTestId('activity-share-chart',hidden).props.style)).toEqual(chart);
  expect(surface().props.payload).toBe(content.payload);
});

test('Activity capture waits for the mounted composition and withdraws readiness when its token changes',()=>{
  jest.useFakeTimers();const ready=jest.fn();
  const view=render(<ActivityShareCard content={content} onReady={ready}/>);
  expect(screen.getByTestId('activity-share-card',hidden).props.ready).toBe(false);
  act(()=>jest.advanceTimersByTime(50));
  expect(screen.getByTestId('activity-share-card',hidden).props.ready).toBe(true);
  view.rerender(<ActivityShareCard content={{...content,token:'replacement'}} onReady={ready}/>);
  expect(screen.getByTestId('activity-share-card',hidden).props.ready).toBe(false);
  view.unmount();expect(ready).toHaveBeenLastCalledWith(false);
});

test.each(['en','de','es','fr','it','ja','ko','pt-BR','zh-Hans','zh-Hant'])('the card renders all summaries and long custom dates in %s without changing its frame',locale=>{
  configurePresentation({locale,textScales:null});
  const date=new Intl.DateTimeFormat(locale,{year:'numeric',month:'long',day:'numeric',timeZone:'UTC'});
  const longContent={...content,startLabel:date.format(new Date('2025-11-28T12:00:00Z')),endLabel:date.format(new Date('2026-02-14T12:00:00Z'))};
  longContent.dateLabel=`${longContent.startLabel} – ${longContent.endLabel}`;
  const card=(period:ActivityShareCardContent['period'],blocked=content.blocked)=><PresentationContext.Provider value={{locale,textScales:null}}><ActivityShareCard content={{...longContent,period,blocked}}/></PresentationContext.Provider>;
  const view=render(card('custom'));
  const frame=StyleSheet.flatten(screen.getByTestId('activity-share-chart',hidden).props.style);
  const formats={today:'Lava helped block %@ requests today.',week:'Lava helped block %@ requests in the last 7 days.',month:'Lava helped block %@ requests this month.',custom:'Lava helped block %@ requests between %@ and %@.'};
  for(const period of ['today','week','month','custom'] as const) for(const blocked of [0,1,content.blocked]) {
    view.rerender(card(period,blocked));
    const format=blocked===1?formats[period].replace('requests','request'):formats[period];
    expect(translations[locale]![format]).toBeDefined();
    if(locale!=='en')expect(localized(format)).not.toBe(format);
    const summary=localizedFormat(format,localizedNumber(blocked),longContent.startLabel,longContent.endLabel);
    const text=screen.getByText(summary,hidden);
    expect(text).toHaveProp('numberOfLines',3);
    expect(text).toHaveProp('adjustsFontSizeToFit',true);
    const [before,after]=localizedFormat(format,'COUNT',longContent.startLabel,longContent.endLabel).split('COUNT');
    expect(text.props.children[0]).toBe(before);
    expect(text.props.children[1].props.children).toBe(localizedNumber(blocked));
    expect(text.props.children[2]).toBe(after);
    expect(screen.getByText(localized('Get Lava and stay protected today'),hidden)).toBeTruthy();
    expect(screen.getByText(longContent.dateLabel,hidden)).toHaveProp('numberOfLines',2);
    expect(StyleSheet.flatten(screen.getByTestId('activity-share-chart',hidden).props.style)).toEqual(frame);
  }
});
