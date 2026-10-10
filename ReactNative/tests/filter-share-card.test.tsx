import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {PixelRatio,StyleSheet} from 'react-native';
import {localized} from '../app/presentation';
import {FilterShareCard,shareCardQrSide,type ShareCardContent} from '../review/FilterShareCard';

const content:ShareCardContent={token:'native-token',payload:'https://lavasecurity.app/app/filter?code=controlled',moduleCount:37,labels:['2 blocklists','1 blocked site','1 custom list','1 allowed site']};
const hidden={includeHiddenElements:true};

afterEach(()=>{jest.useRealTimers();jest.restoreAllMocks();});

test('the full QR has integral modules and four-module clearance even as localized rows consume height',()=>{
  expect(shareCardQrSide(37,882)).toBe(855);
  expect(shareCardQrSide(37,1080)).toBe(945);
  expect(shareCardQrSide(37,730)).toBe(720);
  expect(shareCardQrSide(177,554)).toBe(0);
  expect(shareCardQrSide(37,NaN)).toBe(0);
  expect(shareCardQrSide(178,900)).toBe(0);
});

test.each([1,1.5,2,3])('exports the same physical canvas at device density%s and contains the recipient disclosure',(density)=>{
  jest.spyOn(PixelRatio,'get').mockReturnValue(density);
  render(<FilterShareCard content={content}/>);
  const surface=screen.getByTestId('share-card-export',hidden);
  expect(StyleSheet.flatten(surface.props.style)).toEqual(expect.objectContaining({width:1080/density,height:1350/density,backgroundColor:'#FFFFFF'}));
  expect(surface.props.payload).toBe(content.payload);
  expect(surface.props.ready).toBe(false);
  expect(screen.getByTestId('share-card-heading',hidden)).toHaveStyle({paddingTop:48/density});
  expect(screen.getByTestId('share-card-qr-field',hidden)).toHaveStyle({marginHorizontal:-99/density});
  expect(screen.getByText(localized('Shared by another person. Not reviewed by Lava Security.'),hidden)).toBeTruthy();
  expect(screen.getByText('1 custom list · 1 allowed site',hidden)).toBeTruthy();
  expect(screen.getByText('New? Install, finish setup, then scan again.',hidden).props.allowFontScaling).toBe(false);
});

test('shares only after measured QR placement settles, and a changed native witness loses readiness',()=>{
  jest.useFakeTimers();jest.spyOn(PixelRatio,'get').mockReturnValue(2);
  const ready=jest.fn();
  const view=render(<FilterShareCard content={content} onReady={ready}/>);
  fireEvent(screen.getByTestId('share-card-qr-field',hidden),'layout',{nativeEvent:{layout:{width:441,height:430}}});
  expect(StyleSheet.flatten(screen.getByTestId('share-card-export-qr',hidden).props.style)).toEqual({position:'absolute',left:6.5,top:1,width:427.5,height:427.5});
  expect(screen.getByTestId('share-card-export',hidden).props.ready).toBe(false);
  act(()=>jest.advanceTimersByTime(50));
  expect(screen.getByTestId('share-card-export',hidden).props.ready).toBe(true);
  expect(ready).toHaveBeenLastCalledWith(true);
  view.rerender(<FilterShareCard content={{...content,token:'replaced',moduleCount:45}} onReady={ready}/>);
  expect(screen.getByTestId('share-card-export',hidden).props.ready).toBe(false);
  expect(screen.getByTestId('share-card-export-qr',hidden).props.moduleCount).toBe(45);
  expect(StyleSheet.flatten(screen.getByTestId('share-card-export-qr',hidden).props.style)).toEqual({position:'absolute',left:8.5,top:3,width:424,height:424});
  view.unmount();
  expect(ready).toHaveBeenLastCalledWith(false);
});
