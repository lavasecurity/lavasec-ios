import {Choice,Copy,Section,Symbol,Group,Info,ListRow,Toggle,FlowSheet,FormDivider,FormPanel,FormParagraph} from '../ui';
import {useRef,type ReactNode} from 'react';
import {StagedFlowTransition} from '../StagedFlowTransition';
import {FlowConsentToggle} from '../FlowConsentToggle';
import {ActivityIndicator,View,type ColorValue} from 'react-native';
import {LavaActionButton,type LavaIconAction} from '../../index';
import {colors} from '../../colors';
import {foundation} from '../../foundation';
import {Text} from '../../../app/presentation';
import type {AccountBackupCommandPort,AccountBackupFlowState} from './types';

export type AccountBackupFlowProps={state:AccountBackupFlowState;command:AccountBackupCommandPort;credentials?:ReactNode;confirmAccountDeletion:()=>void;intro?:(summary:string)=>ReactNode;labelColor?:ColorValue;secondaryColor?:ColorValue;labelSymbolTone?:string};
/** Shared task composition. Platform adapters own credentials, auth and navigation. */
export function AccountBackupFlow({state:s,command,credentials,confirmAccountDeletion,intro=summary=><Info title={summary}/>,labelColor=colors.primaryText,secondaryColor=colors.secondaryText,labelSymbolTone='primary'}:AccountBackupFlowProps){
  const action=(title:string,onPress:()=>void,disabled=s.busy,role:'primary'|'panel'='primary',icon?:LavaIconAction,busy?:boolean)=><LavaActionButton title={title} role={role} disabled={disabled} busy={busy} icon={icon} onPress={onPress}/>;
  if(s.kind==='account')return <FlowSheet><Group>
    {s.connections.map(row=><View key={row.provider} style={{minHeight:foundation.row.standard,paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,flexDirection:'row',alignItems:'center',gap:12}}><Symbol name={row.provider==='apple'?'apple.logo':'google.signin'} size={28} pointSize={20} dynamicTypeRamp={row.provider==='apple'?'title3':undefined} weight="semibold" tone="primary"/><Text verbatim numberOfLines={1} ellipsizeMode="middle" allowFontScaling dynamicTypeRamp={foundation.type.row.dynamicTypeRamp} style={{flex:1,fontSize:foundation.type.row.fontSize,fontWeight:foundation.type.row.fontWeight,color:labelColor}}>{row.title}</Text></View>)}
    <ListRow action title="Sign out of all accounts" leading={<Symbol name="rectangle.portrait.and.arrow.right" size={28} pointSize={20} dynamicTypeRamp="title3" weight="semibold" tone="secondary"/>} disabled={s.busy} onPress={()=>void command({action:'account.signOut'})}/>
    <ListRow action title={s.deleting?'Deleting account':'Delete my Lava account'} leading={s.deleting?<View style={{width:28,height:28,alignItems:'center',justifyContent:'center'}}><ActivityIndicator size="small"/></View>:<Symbol name="trash" size={28} pointSize={20} dynamicTypeRamp="title3" weight="semibold" tone="error"/>} color={colors.errorText} disabled={s.busy||s.deleting} onPress={confirmAccountDeletion}/>
  </Group>{!!s.error&&<FormParagraph textRole="note" style={{color:colors.errorText}}>{s.error}</FormParagraph>}</FlowSheet>;
  if(s.success)return <FlowSheet centered footer={action('Done',()=>void command({action:'close'}),false)}><View style={{alignItems:'center',gap:18}}>
    <Symbol name="checkmark.circle.fill" size={66} pointSize={56} responsive={false}/><Copy role="heading" center accessibilityRole="header">{s.kind==='backupSetup'?'Backup is ready':'Restored successfully'}</Copy>
    <Copy role="body" center color={colors.secondaryText}>{s.kind==='backupSetup'?'Your encrypted backup is set up on this device.':'Lava will use the restored settings on this device.'}</Copy>
  </View></FlowSheet>;
  if(s.kind==='backupSetup'){
    const step=s.step==='upload'?'recoveryPhrase':s.step;
    const footer=s.step==='overview'?<View style={{gap:10}}>{s.supportsPasskey?<>
      {action(s.busy&&s.selectedPasskey?'Opening Passkey':'Set up with Passkey',()=>void command({action:'setup.begin',passkey:true}),s.busy,'primary','passkey')}
      {action('Set up without Passkey',()=>void command({action:'setup.begin',passkey:false}),s.busy,'panel')}
    </>:action('Begin Setup',()=>void command({action:'setup.begin',passkey:false}))}</View>
      :s.step==='validatePasskey'?<View style={{gap:10}}>{action(s.busy?'Checking Passkey':'Validate the passkey',()=>void command({action:'setup.validate'}),s.busy,'primary','passkey')}{action('Cancel',()=>void command({action:'setup.cancelValidation'}),s.busy,'panel')}</View>
      :action('Turn On Backup',()=>void command({action:s.step==='upload'?'setup.retry':'setup.finish'}),s.busy||s.uploading||!s.canContinue,'primary',undefined,s.busy||s.uploading);
    return <FlowSheet footer={footer}><SetupTransition step={step}><View style={{gap:14}}>
      {step==='overview'?<>{intro('Encrypted on this device. Only you can unlock your backup.')}
        <FormPanel>{[['key','This device','A local unlock key stays on this device.'],['person.badge.key','Passkey','Restore with your password manager.'],['text.badge.checkmark','Recovery phrase','Keep it safe to restore with your account.']].map(([icon,title,detail],index)=><View key={title} style={{gap:12}}>{index>0&&<FormDivider/>}<Fact icon={icon!} title={title!} detail={detail!} labelColor={labelColor}/></View>)}</FormPanel></>
        :step==='validatePasskey'?intro('Try your passkey now. You’ll use it to restore your backup.')
        :<>{intro('Copy these eight words, then save them somewhere safe outside Lava.')}<FormPanel>{credentials}</FormPanel>
          <Group><Toggle titleColor={labelColor} title="I have saved my recovery phrase in a secure, accessible place" value={s.saved} disabled={s.busy||s.step==='upload'} optimistic={false} onChange={saved=>command({action:'setup.consent',saved,understands:s.understands})}/>
          <Toggle titleColor={labelColor} title="I understand that if I lose every unlock method, I may not be able to restore my backup" value={s.understands} disabled={s.busy||s.step==='upload'} optimistic={false} onChange={understands=>command({action:'setup.consent',saved:s.saved,understands})}/></Group></>}
      {s.step==='upload'&&!!s.uploadError&&<FormParagraph textRole="note">{s.uploadError}</FormParagraph>}
      {!!s.error&&<FormParagraph textRole="note" style={{fontWeight:'600',color:colors.lavaOrangeText}}>{s.error}</FormParagraph>}
    </View></SetupTransition></FlowSheet>;
  }
  return <FlowSheet footer={action(s.busy?'Restoring':s.review?'Restore Backup':'Review Backup',()=>void command({action:s.review?'restore.confirm':'restore.prepare'}),s.busy||!s.canContinue,'primary','restoreBackup')}>
    <Info title="Bring your settings back" description="Unlock your backup, review its changes, then restore." icon="icloud.and.arrow.down"/>
    <Section title={s.review?'Review Backup':'Unlock method'} footer={s.review?'Restoring replaces your current filters and settings.':undefined}><View style={{gap:14}}>
      {s.status&&<Info title={s.status.title} description={s.status.detail} tone={s.status.tone} icon="icloud.and.arrow.down.fill"/>}
      {s.review?<><Text allowFontScaling dynamicTypeRamp="caption1" style={{fontSize:12,color:secondaryColor}}>Current → Backup</Text>{s.review.map((section,index)=>index===0?<ReviewRows key={section.id} rows={section.rows} labelColor={labelColor} secondaryColor={secondaryColor}/>:<FormPanel key={section.id}><View style={{gap:8}}><ReviewRows rows={section.rows} gap={8} labelColor={labelColor} secondaryColor={secondaryColor}/>{section.notes.map(note=><FormParagraph key={note.text} verbatim textRole={note.role==='cacheWarning'?'note':'supporting'} style={note.role==='contentChange'?{color:labelColor}:undefined}>{note.text}</FormParagraph>)}</View></FormPanel>)}
        {s.resolverConfirmationRequired&&<FlowConsentToggle testID="backup.restore.consent" title="I confirm these DNS changes" value={s.resolverConfirmed} labelColor={labelColor} disabled={s.busy} onChange={value=>command({action:'restore.consent',value})}/>}</>
        :<FormPanel><View style={{gap:14}}><Choice label="Unlock method" options={s.modes.map(mode=>mode.title)} value={s.modes.find(mode=>mode.id===s.mode)?.title??''} disabled={s.busy} onChange={title=>{const mode=s.modes.find(item=>item.title===title);if(mode&&!mode.unavailable)void command({action:'restore.mode',mode:mode.id});}}/>
          {s.mode==='recoveryCode'?<View style={{gap:10}}><FormParagraph textRole="note">Use only a recovery phrase you saved yourself.</FormParagraph>{credentials}<FormParagraph textRole="note">Spaces and capitalization do not matter. Press space to jump to the next word.</FormParagraph></View>
            :<RestoreMethodHint mode={s.mode} labelColor={labelColor} labelSymbolTone={labelSymbolTone}/>}</View></FormPanel>}
    </View></Section>
  </FlowSheet>;
}
function Fact({icon,title,detail,labelColor}:{icon:string;title:string;detail?:string;labelColor:ColorValue}){return <View accessible style={{flexDirection:'row',alignItems:'flex-start',gap:12}}><Symbol name={icon} size={24} pointSize={17} dynamicTypeRamp="headline" weight="semibold" tone="primary"/><View style={{flex:1,gap:3}}><Copy role="section" color={labelColor}>{title}</Copy>{detail&&<FormParagraph textRole="body" style={{color:colors.secondaryText}}>{detail}</FormParagraph>}</View></View>;}
function RestoreMethodHint({mode,labelColor,labelSymbolTone}:{mode:'deviceKey'|'passkey';labelColor:ColorValue;labelSymbolTone:string}){return <View accessible style={{minHeight:44,flexDirection:'row',alignItems:'center',gap:7}}><Symbol name={mode==='deviceKey'?'iphone':'person.badge.key'} size={20} pointSize={15} dynamicTypeRamp="subheadline" weight="semibold" tone={labelSymbolTone}/><Copy role="row" color={labelColor}>{mode==='deviceKey'?"Use this device's keychain":'Use your saved passkey'}</Copy></View>;}
function ReviewRows({rows,gap=14,labelColor,secondaryColor}:{rows:{title:string;before:string;after:string;notes?:string[]}[];gap?:number;labelColor:ColorValue;secondaryColor:ColorValue}){return <View style={{gap}}>{rows.map((row,index)=><View key={`${row.title}:${index}`} style={{gap:4}}><View accessible style={{gap:4}}><Copy role="row" weight="600" color={labelColor}>{row.title}</Copy><FormParagraph verbatim style={{color:secondaryColor}}>{row.before+' → '+row.after}</FormParagraph></View>{row.notes?.map(note=><FormParagraph key={note} verbatim style={{color:labelColor}}>{note}</FormParagraph>)}</View>)}</View>;}

function SetupTransition({step,children}:{step:AccountBackupFlowState['step'];children:ReactNode}){
  const previous=useRef(step);const direction=useRef<'forward'|'backward'>('forward');
  const order=['overview','validatePasskey','recoveryPhrase','upload','complete'];
  if(previous.current!==step){direction.current=order.indexOf(step)>=order.indexOf(previous.current)?'forward':'backward';previous.current=step;}
  return <StagedFlowTransition stageID={step} direction={direction.current} stretch={false}>{children}</StagedFlowTransition>;
}
