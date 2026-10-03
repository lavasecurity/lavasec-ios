import {useRef,useState} from 'react';
import {ScrollView, StyleSheet, View} from 'react-native';
import {LavaActionButton, LavaCard, LavaChoice, LavaIconButton, LavaText, LavaToggleRow} from '../src';
import {Copy,Row,Section} from '../review/primitives';
import {AccessorySlot,Group,Info,ListRow} from '../review/scaffold';
import {SettingsControl,SettingsDisclosure,SettingsGroup,SettingsInset,SettingsMessage,SettingsSurface,SettingsTextPreview} from '../review/settings-scaffold';
import {DetailField,DetailReviewValue} from '../review/detail-scaffold';
import {ConnectionPanel,ExploreInvitation} from '../review/story-scaffold';
import {connectionStages} from '../review/connection-model';
import {initialSession} from '../review/session';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors.ios';
import {lavaTokens} from '../src/generated/tokens';

// Review fixtures, not product catalog strings or live protection state. No clock,
// network, account, or random data participates in the component baseline.
export function LavaComponentGallery() {
  const [enabled, setEnabled] = useState(false);
  const [presses, setPresses] = useState(0);
  const [requestedChoice, setRequestedChoice] = useState('normal');
  const [disabledChoiceRequests, setDisabledChoiceRequests] = useState(0);
  const [confirmedAsyncChoice,setConfirmedAsyncChoice]=useState('normal');
  const [asyncChoice,setAsyncChoice]=useState<string>();
  const finishAsyncChoice=useRef<()=>void>(()=>{});
  const settleChoice=(accept:boolean)=>{if(accept&&asyncChoice)setConfirmedAsyncChoice(asyncChoice);setAsyncChoice(undefined);finishAsyncChoice.current();};
  const [detailsOpen,setDetailsOpen]=useState(false);
  const [noticeOpen,setNoticeOpen]=useState(false);
  const [exampleDNS,setExampleDNS]=useState('https://dns.example/dns-query');
  const [selectedFilter,setSelectedFilter]=useState('Core');
  const [lockedChoiceRequests,setLockedChoiceRequests]=useState(0);
  const choices = [{value: 'normal', label: 'Normal'}, {value: 'focused', label: 'Focused'}];
  return <ScrollView testID="lava-component-gallery" contentInsetAdjustmentBehavior="automatic" style={styles.screen} contentContainerStyle={styles.content}>
    <LavaCard><LavaText role="cardTitle">Lava component review</LavaText></LavaCard>
    <LavaCard role="panel"><LavaText role="cardTitle">Protection is on</LavaText></LavaCard>
    <LavaCard><View style={styles.stack}>
      <LavaText role="rowTitle">Row title</LavaText>
      <LavaText role="rowTitle" tone="secondary">Secondary label</LavaText>
      <LavaText role="rowTitle" tone="warning">Needs attention</LavaText>
      <LavaText role="rowTitle" tone="danger">Could not complete</LavaText>
      <LavaText role="metricNumeral">1,024</LavaText>
    </View></LavaCard>
    <SettingsSurface><LavaToggleRow title="Protection feedback" value={enabled} onValueChange={setEnabled} /></SettingsSurface>
    <SettingsSurface><LavaToggleRow title="Disabled setting" value disabled onValueChange={() => {}} /></SettingsSurface>
    <LavaCard><View style={styles.stack}>
      <LavaChoice label="Async confirmation" options={choices} value={confirmedAsyncChoice} disabled={!!asyncChoice} onValueChange={value=>{setAsyncChoice(value);return new Promise<void>(resolve=>{finishAsyncChoice.current=resolve;});}}/>
      <LavaText>{`Saved async choice: ${confirmedAsyncChoice}`}</LavaText>
      <LavaActionButton title="Accept choice" disabled={!asyncChoice} onPress={()=>settleChoice(true)}/>
      <LavaActionButton title="Cancel choice" disabled={!asyncChoice} onPress={()=>settleChoice(false)}/>
    </View></LavaCard>
    <LavaCard><View style={styles.stack}>
      <LavaText role="rowTitle">Choice awaiting confirmation</LavaText>
      <LavaChoice label="Pending confirmation" options={choices} value="normal" onValueChange={setRequestedChoice} />
      <LavaText tone="secondary">{`Requested: ${requestedChoice} · Confirmed: normal`}</LavaText>
      <LavaText tone="secondary">This gallery fixture keeps the confirmed choice unchanged.</LavaText>
      <LavaChoice label="Disabled choice" options={choices} value="normal" disabled onValueChange={() => setDisabledChoiceRequests(count => count + 1)} />
      <LavaText tone="secondary">{`Disabled choice requests: ${disabledChoiceRequests}`}</LavaText>
    </View></LavaCard>
    <SettingsSurface><LavaToggleRow title="Eine längere Bezeichnung, die bei größerer Schrift mehr Platz benötigt" value={false} onValueChange={() => {}} /></SettingsSurface>
    <SettingsSurface><SettingsControl title="Choice awaiting confirmation"><LavaChoice presentation="stepper" label="Pending confirmation" options={choices} value="normal" onValueChange={setRequestedChoice}/></SettingsControl></SettingsSurface>
    {(['primary', 'panel', 'secondary'] as const).map(role => <View key={role} style={styles.stack}>
      <LavaActionButton title={`${role} action`} role={role} onPress={() => setPresses(count => count + 1)} />
      <LavaActionButton title={`${role} disabled`} role={role} disabled onPress={() => {}} />
    </View>)}
    <LavaCard><LavaText role="rowTitle">{`Actions received: ${presses}`}</LavaText></LavaCard>
    <Section title="One circular control">
      <View style={styles.controls}>{(['back','close','delete','undo','confirm'] as const).map(icon=><LavaIconButton key={icon} icon={icon} title={icon} role={icon==='delete'?'destructive':'neutral'} selected={icon==='confirm'} onPress={()=>setPresses(count=>count+1)}/>)}</View>
      <View style={styles.controls}><LavaIconButton icon="confirm" title="No pending changes" disabled onPress={()=>{}}/><LavaIconButton icon="confirm" title="Confirm pending changes" selected onPress={()=>setPresses(count=>count+1)}/></View>
    </Section>
    <Section title="One accessory axis">
      <Group><ListRow title="Read mode" metadata="Same label and accessory positions" trailing={false}/><ListRow title="Edit mode" metadata="Same label and accessory positions" trailing={<AccessorySlot><LavaIconButton icon="delete" title="Delete example" role="destructive" onPress={()=>{}}/></AccessorySlot>}/></Group>
    </Section>
    <Section title="Open destinations"><Row title="Your connection" icon="network" intent="page" onPress={()=>{}}/><Row title="Help" icon="questionmark.circle" intent="external" onPress={()=>{}}/></Section>
    <Section title="Related destinations">
      <ConnectionPanel stages={connectionStages(undefined,initialSession())} onSelect={()=>setPresses(count=>count+1)} onExplore={()=>setPresses(count=>count+1)}/>
      <SettingsGroup title="Your Lava"><Row title="Account & Backup" icon="person.crop.circle" intent="page" onPress={()=>setPresses(count=>count+1)}/></SettingsGroup>
      <ExploreInvitation onPress={()=>setPresses(count=>count+1)}/>
    </Section>
    <SettingsDisclosure title="Occasional actions" icon="ellipsis.circle" expanded={detailsOpen} onChange={setDetailsOpen}>
      <ListRow title="Review an action" onPress={()=>setPresses(count=>count+1)}/>
      <SettingsInset><SettingsMessage>A consequence stays beside its action.</SettingsMessage></SettingsInset>
    </SettingsDisclosure>
    <SettingsDisclosure title="Third-party notices" expanded={noticeOpen} onChange={setNoticeOpen}>
      <SettingsInset><Copy role="body">All other trademarks and service marks are property of their respective owners.</Copy></SettingsInset>
    </SettingsDisclosure>
    <SettingsGroup title="Live text preview"><SettingsTextPreview/></SettingsGroup>
    <Section title="Primary DNS"><DetailField title="Primary DNS" value={exampleDNS} onChangeText={setExampleDNS}/><DetailReviewValue label="Primary DNS">{exampleDNS}</DetailReviewValue></Section>
    <Section title="Information and state"><Info title="A quiet explanation" description="One clear sentence at the point it helps." icon="info.circle"/><Info title="Review before continuing" description="A consequence stays next to its action." warning icon="exclamationmark.triangle"/><LavaActionButton title="Saving changes" busy disabled onPress={()=>{}}/></Section>
    <Section title="Type roles">{(['title','heading','section','body','supporting','caption'] as const).map(role=><Copy key={role} role={role}>{role}</Copy>)}</Section>
    <Section title="One selection slot">
      <Group testID="gallery.selection">
        {['Core','Balanced'].map(title=><ListRow key={title} title={title} selected={selectedFilter===title} onPress={()=>setSelectedFilter(title)}/>)}
        <ListRow title="Disabled selection" selected disabled onPress={()=>setSelectedFilter('disabled')}/>
        <ListRow title="Locked option" selected={false} selectionLocked metadata={`Requests: ${lockedChoiceRequests}`} onPress={()=>setLockedChoiceRequests(count=>count+1)}/>
      </Group>
    </Section>
  </ScrollView>;
}

const styles = StyleSheet.create({
  controls:{flexDirection:'row',flexWrap:'wrap',gap:foundation.space.md},
  screen: {flex: 1, backgroundColor: colors.groupedBackground},
  content: {
    width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',
    gap: lavaTokens.spacing.xl, paddingHorizontal: lavaTokens.spacing.screenHorizontal,
    paddingTop: lavaTokens.spacing.screenTop, paddingBottom: lavaTokens.spacing.screenBottom,
  },
  stack: {gap: lavaTokens.spacing.md},
});
