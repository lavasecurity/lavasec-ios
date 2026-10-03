import {useEffect, useRef, useState, type PropsWithChildren} from 'react';
import {View} from 'react-native';

// Keep the existing content height, including its note, while a different query scope is loading.
// The accepted result can resize once; a transient loading row cannot collapse
// the scroll view and force UIKit to move its large title or scroll position.
export function QueryContent({pending, children, testID}: PropsWithChildren<{pending: boolean; testID?: string}>) {
  const height = useRef(0);
  return <View testID={testID} style={[{gap: 10}, pending && height.current > 0 ? {minHeight: height.current} : undefined]}
    onLayout={event => {if (!pending) height.current = event.nativeEvent.layout.height;}}>{children}</View>;
}

export function useSettledSearch(value: string): string {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    if (!value) {setSettled(''); return;}
    const timer = setTimeout(() => setSettled(value), 200);
    return () => clearTimeout(timer);
  }, [value]);
  return value ? settled : '';
}
