import {Copy,Section,RowAccessory,Group,ListRow,FlowSheet} from '../ui';
import {View} from 'react-native';
import type {ComponentType,PropsWithChildren,ReactNode} from 'react';
import {colors} from '../../colors';
import {foundation} from '../../foundation';

export type DNSHelpPort={openDNS:()=>void;openVPN:()=>void;openSettings:()=>void;openSupport:()=>void;profileGlyph:ReactNode};
export type DNSInstructionRowProps={badge:ReactNode;children:ReactNode};
/** Instruction composition has no dependency on an iOS bridge or navigation implementation. */
export function DNSHelpScreen({profileEnabled,port,paragraph:Paragraph=DNSParagraph,instructionRow:Row=DNSInstructionRow,page:Page=FlowSheet}:{profileEnabled:boolean;port:DNSHelpPort;paragraph?:ComponentType<PropsWithChildren>;instructionRow?:ComponentType<DNSInstructionRowProps>;page?:ComponentType<PropsWithChildren>}){
  return <Page><View testID="dns-patch-page" style={{gap:20}}>
    <Group tone="green"><View><View style={{padding:foundation.space.lg}}><Paragraph>In iOS 27, Connectivity Assist replaces Wi-Fi Assist. It helps keep you online when Wi-Fi is weak, but it can also retry websites blocked by Lava over cellular, weakening filtering on Wi-Fi.</Paragraph></View>
      <View style={{padding:foundation.space.lg}}><Paragraph>To keep Lava effective, choose one of these options.</Paragraph></View></View>
      <ListRow trailingRole="disclosure" title="More about Connectivity Assist" onPress={port.openSupport} trailing={<RowAccessory intent="external"/>}/>
    </Group>
    <InstructionSection paragraph={Paragraph} row={Row} title="Use Lava’s DNS profile · Recommended" steps={['Open DNS settings and configure System DNS.','In the Settings app, go to General → VPN & Device Management → DNS.','Select “Lava Security”, then return to Lava and turn on protection.']}>
      <ListRow trailingRole="disclosure" title={profileEnabled?'DNS profile enabled':'Set up in DNS settings'} leading={port.profileGlyph} onPress={port.openDNS} trailing={<RowAccessory intent="page"/>}/>
    </InstructionSection>
    <InstructionSection paragraph={Paragraph} row={Row} title="Turn off Connectivity Assist" steps={['In the Settings app, tap Wi-Fi.','Scroll down and turn off Connectivity Assist.','Keep protection on in Lava.']}>
      <ListRow trailingRole="disclosure" title="Open the Settings app" onPress={port.openSettings} trailing={<RowAccessory intent="external"/>}/>
    </InstructionSection>
    <InstructionSection paragraph={Paragraph} row={Row} title="Use Full Tunnel (requires Lava Plus)" steps={['Open VPN chaining.','Import a full-tunnel WireGuard configuration.','Turn on “Chain DNS through my VPN”, then turn on protection.']}>
      <ListRow trailingRole="disclosure" title="Open VPN chaining" onPress={port.openVPN} trailing={<RowAccessory intent="page"/>}/>
    </InstructionSection>
  </View></Page>;
}
function DNSParagraph({children}:PropsWithChildren){return <Copy role="supporting" color={colors.primaryText}>{children}</Copy>;}
function DNSInstructionRow({badge,children}:DNSInstructionRowProps){return <View style={{flexDirection:'row',alignItems:'baseline',gap:foundation.space.md}}>{badge}<View style={{flex:1}}>{children}</View></View>;}
function InstructionSection({title,steps,children,paragraph:Paragraph,row:Row}:{title:string;steps:readonly string[];children:ReactNode;paragraph:ComponentType<PropsWithChildren>;row:ComponentType<DNSInstructionRowProps>}){
  return <Section title={title}><Group><View testID="dns.instructions" style={{paddingHorizontal:foundation.space.infoPanelHorizontalInset,paddingVertical:foundation.space.infoPanelVerticalInset,gap:foundation.space.md}}>
    {steps.map((step,index)=><Row key={step} badge={<View style={{width:22,height:22,borderRadius:11,backgroundColor:colors.softGreen,alignItems:'center',justifyContent:'center'}}><Copy role="row" color={colors.safeGreen} verbatim>{String(index+1)}</Copy></View>}><Paragraph>{step}</Paragraph></Row>)}
  </View>{children}</Group></Section>;
}
