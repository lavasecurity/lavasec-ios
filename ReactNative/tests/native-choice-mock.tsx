import type {ComponentProps} from 'react';
import {Pressable, Text, View} from 'react-native';
import type NativeChoice from '../specs/LavaChoiceNativeComponent';

// Emulate only Fabric events/props. UIKit rendering and selection rollback are
// exercised by ReviewLifecycleTests in the Simulator, not by this JS boundary.
export default function NativeChoiceMock(props: ComponentProps<typeof NativeChoice>) {
  return <View {...props}>
    {props.options.map(option => <Pressable key={option.value} accessibilityRole="button"
      accessibilityLabel={option.label} accessibilityState={{selected: props.value === option.value, disabled: props.disabled}}
      disabled={props.disabled} onPress={() => props.onValueChange?.({nativeEvent: {value: option.value}} as never)}>
      <Text>{option.label}</Text>
    </Pressable>)}
  </View>;
}
