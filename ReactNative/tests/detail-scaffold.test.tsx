import {fireEvent,render,screen} from '@testing-library/react-native';
import {PresentationContext} from '../app/presentation';
import {DetailField,DetailReviewValue,DetailSteps} from '../review/detail-scaffold';
import {InputRow} from '../review/scaffold';
import {Section} from '../review/primitives';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({})}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

test('editable and review fields share label anatomy and semantic text scaling',()=>{
  const content=(textScales:Record<string,number>|null)=><PresentationContext.Provider value={{locale:'en',textScales}}>
    <Section title="Custom Resolver">
      <DetailField title="Primary DNS" value="https://dns.example/query" onChangeText={()=>{}}/>
      <DetailReviewValue label="Review DNS">https://dns.example/query</DetailReviewValue>
    </Section>
  </PresentationContext.Provider>;
  render(content(null));
  expect(screen.UNSAFE_getAllByType(InputRow)).toHaveLength(2);
  for(const title of ['Primary DNS','Review DNS']){
    expect(screen.getByText(title)).toHaveStyle({fontSize:13,fontWeight:'600'});
    expect(screen.getByText(title)).toHaveProp('dynamicTypeRamp','footnote');
    expect(screen.getByText(title).props.numberOfLines).toBeUndefined();
  }
  expect(screen.getByRole('header',{name:'Custom DNS'})).toHaveStyle({fontSize:17,fontWeight:'600'});
  screen.rerender(content({footnote:2,headline:1.5,body:1.25}));
  for(const title of ['Primary DNS','Review DNS'])expect(screen.getByText(title)).toHaveStyle({fontSize:26,fontWeight:'600'});
  expect(screen.getByRole('header',{name:'Custom DNS'})).toHaveStyle({fontSize:25.5,fontWeight:'600'});
  expect(screen.getByLabelText('Primary DNS')).toHaveStyle({fontSize:21.25});
  expect(screen.getByText('https://dns.example/query')).toHaveStyle({fontSize:21.25});
});

test('a compact shared field follows the app text scale without becoming a large message editor',()=>{
  const changed=jest.fn();
  const content=(scale:number)=><PresentationContext.Provider value={{locale:'en',textScales:{body:scale}}}>
    <DetailField title="DNS address" multiline compactMultiline value="https://dns.example/query" onChangeText={changed}/>
  </PresentationContext.Provider>;
  render(content(2));
  const field=()=>screen.getByLabelText('DNS address');
  expect(field()).toHaveStyle({fontSize:34});
  expect(field().props.allowFontScaling).toBe(false);
  expect(field().props.style[1].minHeight).toBeLessThan(132);
  fireEvent.changeText(field(),'https://dns.example/new');
  expect(changed).toHaveBeenCalledWith('https://dns.example/new');
  screen.rerender(content(3));
  expect(field()).toHaveStyle({fontSize:51});
  expect(field().props.style[1].minHeight).toBeGreaterThan(51);
});

test('shared steps permit returning to reached pages without skipping required steps',()=>{
  const select=jest.fn();
  const content=(current:number,furthest:number)=><DetailSteps titles={['Topic','Details','Review']} current={current} furthest={furthest} onSelect={select}/>;
  render(content(0,0));
  expect(screen.getByRole('button',{name:'3. Review'})).toBeDisabled();
  fireEvent.press(screen.getByRole('button',{name:'3. Review'}));
  expect(select).not.toHaveBeenCalled();
  screen.rerender(content(1,1));
  fireEvent.press(screen.getByRole('button',{name:'1. Topic'}));
  expect(select).toHaveBeenLastCalledWith(0);
  expect(screen.getByRole('button',{name:'2. Details',selected:true})).toBeOnTheScreen();
});
