import {useContext} from 'react';
import {useWindowDimensions} from 'react-native';
import {PresentationContext} from './presentation';
import {useWindowLayout} from '../src/window-layout';

// Non-Text controls must use the same override as presentation.Text. Otherwise
// native editors and decoration boxes stay small when their labels grow.
export function useAccessibilityTextScale(ramp = 'body'): number {
  const {textScales} = useContext(PresentationContext);
  const {fontScale} = useWindowDimensions();
  return textScales?.[ramp] ?? fontScale;
}

export function useTextScale(ramp = 'body'): number {
  return useAccessibilityTextScale(ramp)*useWindowLayout().scale;
}
