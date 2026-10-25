import {Copy,RowAccessory,Group,ListRow,FlowSheet} from '../ui';
import {View} from 'react-native';
import type {ComponentType,PropsWithChildren,ReactNode} from 'react';
import {SetupSection} from '../SetupSection';
import {colors} from '../../colors';
import {foundation} from '../../foundation';

export type DNSHelpPort={openDNS:()=>void;openVPN:()=>void;openSettings:()=>void;openSupport:()=>void;profileGlyph:ReactNode};
/** Instruction composition has no dependency on an iOS bridge or navigation implementation. */
export function DNSHelpScreen({profileEnabled,port,page:Page=FlowSheet}:{profileEnabled:boolean;port:DNSHelpPort;page?:ComponentType<PropsWithChildren>}){
  return <Page><View testID="dns-patch-page" style={{gap:20}}>
    <Group tone="green"><View><View style={{padding:foundation.space.lg}}><Copy role="supporting" color={colors.primaryText}>In iOS 27, Connectivity Assist replaces Wi-Fi Assist. It helps keep you online when Wi-Fi is weak, but it can also retry websites blocked by Lava over cellular, weakening filtering on Wi-Fi.</Copy></View>
      <View style={{padding:foundation.space.lg}}><Copy role="supporting" color={colors.primaryText}>To keep Lava effective, choose one of these options.</Copy></View></View>
      <ListRow trailingRole="disclosure" title="More about Connectivity Assist" onPress={port.openSupport} trailing={<RowAccessory intent="external"/>}/>
    </Group>
    <SetupSection title="Use Lava’s DNS profile · Recommended" steps={['Open DNS settings and configure System DNS.','In the Settings app, go to General → VPN & Device Management → DNS.','Select “Lava Security”, then return to Lava and turn on protection.']}>
      <ListRow trailingRole="disclosure" title={profileEnabled?'DNS profile enabled':'Set up in DNS settings'} leading={port.profileGlyph} onPress={port.openDNS} trailing={<RowAccessory intent="page"/>}/>
    </SetupSection>
    <SetupSection title="Turn off Connectivity Assist" steps={['In the Settings app, tap Wi-Fi.','Scroll down and turn off Connectivity Assist.','Keep protection on in Lava.']}>
      <ListRow trailingRole="disclosure" title="Open the Settings app" onPress={port.openSettings} trailing={<RowAccessory intent="external"/>}/>
    </SetupSection>
    <SetupSection title="Use Full Tunnel (requires Lava Plus)" steps={['Open VPN chaining.','Import a full-tunnel WireGuard configuration.','Turn on “Chain DNS through my VPN”, then turn on protection.']}>
      <ListRow trailingRole="disclosure" title="Open VPN chaining" onPress={port.openVPN} trailing={<RowAccessory intent="page"/>}/>
    </SetupSection>
  </View></Page>;
}
