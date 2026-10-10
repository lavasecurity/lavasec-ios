import {View} from 'react-native';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {LavaActionButton} from '../src';
import {Copy,Section} from './primitives';
import {Group,ListRow} from './scaffold';
import {RowAccessory} from './primitives';
import {SettingsIntro} from './settings-scaffold';
import {FlowSheet} from './form-scaffold';
import {useReview} from './ReviewContext';
import {Alert} from '../app/presentation';
import {SetupSection} from './settings-scaffold';

export function AutoSwitchContent(){
  const {app}=useReview();
  const open=(target:'shortcuts'|'settings')=>{void app?.command({type:'system.open',target}).catch(error=>Alert.alert('Lava',error.message));};
  return <>
    <SettingsIntro summary="Switch filters on a schedule or with a Focus."/>
    <SetupSection title="Automation" steps={['In Shortcuts, create an automation for a time, place, or event.','Add the Lava Switch Filter action, then pick a filter.']} action={{title:'Open Shortcuts',onPress:()=>open('shortcuts')}}/>
    <SetupSection title="Focus mode" steps={['Open the Settings app, then tap Focus.','Choose a Focus like Sleep or Work — or create one.','Tap Focus Filters, then Add Filter.','Choose Lava, then pick the filter to switch to.']} action={{title:'Open the Settings app',onPress:()=>open('settings')}} note="Opens Lava's page in Settings — tap back, then Focus."/>
  </>;
}
export function AutoSwitchPage(){return <FlowSheet><View testID="auto-switch-page" style={{gap:20}}><AutoSwitchContent/></View></FlowSheet>;}
