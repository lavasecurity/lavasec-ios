import {useState} from 'react';
import {StyleSheet,View} from 'react-native';
import {fireEvent,render,screen} from '@testing-library/react-native';
import {ListRow} from '../review/scaffold';
import {LavaIconButton,LavaRowLabel,LavaSelectionAccessory} from '../src';
import {colors} from '../src/colors.ios';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({})}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

test('single selection changes only through the row owner and has no second accessible control',()=>{
  const changed=jest.fn();
  function Choices(){
    const [selected,setSelected]=useState('Core');
    return <>{['Core','Balanced'].map(title=><ListRow key={title} title={title} selected={title===selected}
      onPress={()=>{changed(title);setSelected(title);}}/>)}</>;
  }
  render(<Choices/>);
  expect(changed).not.toHaveBeenCalled();
  expect(screen.getAllByRole('button')).toHaveLength(2);
  expect(screen.getAllByRole('button',{selected:true})).toHaveLength(1);
  expect(screen.UNSAFE_getAllByType(LavaSelectionAccessory).map(mark=>mark.props.state)).toEqual(['selected','unselected']);
  fireEvent.press(screen.getByRole('button',{name:'Balanced'}));
  expect(changed).toHaveBeenCalledTimes(1);
  expect(changed).toHaveBeenCalledWith('Balanced');
  expect(screen.getByRole('button',{name:'Core'})).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
  expect(screen.getByRole('button',{name:'Balanced'})).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  expect(screen.UNSAFE_getAllByType(LavaSelectionAccessory).map(mark=>mark.props.state)).toEqual(['unselected','selected']);
});

test('multi-selection remains independent and a custom-list delete is outside the row target',()=>{
  const removed=jest.fn();
  function Choices(){
    const [selected,setSelected]=useState(['Basic']);
    return <>{['Basic','Custom'].map(title=><ListRow key={title} title={title} selected={selected.includes(title)} separateTrailing
      trailing={title==='Custom'?<LavaIconButton title="Delete custom blocklist" icon="delete" onPress={removed}/>:undefined}
      onPress={()=>setSelected(previous=>previous.includes(title)?previous.filter(item=>item!==title):[...previous,title])}/>)}</>;
  }
  render(<Choices/>);
  fireEvent.press(screen.getByRole('button',{name:'Custom'}));
  expect(screen.getAllByRole('button',{selected:true})).toHaveLength(2);
  fireEvent.press(screen.getByRole('button',{name:'Delete custom blocklist'}));
  expect(removed).toHaveBeenCalledTimes(1);
  expect(screen.getAllByRole('button',{selected:true})).toHaveLength(2);
  fireEvent.press(screen.getByRole('button',{name:'Basic'}));
  expect(screen.getByRole('button',{name:'Basic'})).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
  expect(screen.getByRole('button',{name:'Custom'})).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
});

test('disabled selection retains its check while a locked option remains a separate unavailable state',()=>{
  const change=jest.fn();
  render(<View><ListRow title="Current" selected disabled onPress={change}/><ListRow title="Locked" selected={false} selectionLocked disabled onPress={change}/></View>);
  for(const name of ['Current','Locked'])fireEvent.press(screen.getByRole('button',{name}));
  expect(change).not.toHaveBeenCalled();
  expect(screen.getByRole('button',{name:'Current'})).toHaveProp('accessibilityState',expect.objectContaining({selected:true,disabled:true}));
  expect(screen.getByRole('button',{name:'Locked'})).toHaveProp('accessibilityState',expect.objectContaining({selected:false,disabled:true}));
  const symbols=screen.UNSAFE_getAllByType(View).filter(view=>view.props.symbol);
  expect(symbols.map(symbol=>[symbol.props.symbol,symbol.props.tone])).toEqual([
    ['checkmark.circle.fill','secondary'],['lock.fill','secondary'],
  ]);
  expect(screen.getAllByRole('button')).toHaveLength(2);
});

test('selection and ordinary rows share label anatomy without losing verbatim identity, metadata or error semantics',()=>{
  const open=jest.fn();
  render(<ListRow title="Cancel" verbatimTitle subtitle="Download failed" metadata="Retry" metadataPrefix="Error" color={colors.errorText}
    selected={false} pending onPress={open}/>);
  const row=screen.getByRole('button',{name:'Cancel, Download failed'});
  expect(row).toHaveProp('accessibilityValue',expect.objectContaining({text:'Error, Try again'}));
  const label=screen.UNSAFE_getByType(LavaRowLabel);
  expect(label.props).toMatchObject({title:'Cancel',verbatimTitle:true,summary:'Download failed',strike:true,titleColor:colors.errorText});
  expect(StyleSheet.flatten(screen.getByText('Cancel').props.style)).toMatchObject({color:colors.errorText,textDecorationLine:'line-through'});
  expect(screen.getByText('Download failed')).toHaveProp('dynamicTypeRamp','subheadline');
  expect(screen.UNSAFE_getByType(LavaSelectionAccessory).props.state).toBe('unselected');
  expect(screen.UNSAFE_getAllByType(View).filter(view=>view.props.symbol)).toHaveLength(0);
  fireEvent.press(row);
  expect(open).toHaveBeenCalledTimes(1);
});
